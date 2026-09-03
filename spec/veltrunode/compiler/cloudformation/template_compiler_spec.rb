# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'tmpdir'
require 'veltrunode/compiler/cloudformation'
require 'veltrunode/dsl'

RSpec.describe Veltrunode::Compiler::CloudFormation::TemplateCompiler do
  let(:minimal_application) do
    Veltrunode::Model::Application.new(
      name: 'simple-service',
      region: 'ap-northeast-1',
      stage: 'dev',
      functions: [
        Veltrunode::Model::Function.new(
          logical_name: 'worker',
          handler: 'functions/worker.handler',
          runtime: 'ruby3.3'
        )
      ]
    )
  end

  let(:full_application) do
    Veltrunode::Model::Application.new(
      name: 'document-processor',
      region: 'ap-northeast-1',
      stage: 'production',
      runtime_defaults: {
        logs: { retention_days: 60 }
      },
      layers: [
        Veltrunode::Model::Layer.new(
          name: 'runtime_gems',
          compatible_runtimes: %w[ruby3.3 ruby3.4],
          architectures: %i[arm64],
          description: 'Bundler runtime gems'
        )
      ],
      functions: [
        Veltrunode::Model::Function.new(
          logical_name: 'convert',
          handler: 'functions/convert.handler',
          runtime: 'ruby3.3',
          architecture: :arm64,
          memory: 4096,
          timeout: 900,
          layers: ['runtime_gems'],
          environment: { 'STAGE' => 'production' }
        )
      ],
      schedules: [
        Veltrunode::Model::Schedule.new(
          name: 'nightly_sync',
          target_function: 'convert',
          expression_type: :cron,
          expression: '0 1 * * ? *',
          timezone: 'Asia/Tokyo',
          dlq: 'nightly_dlq'
        )
      ]
    )
  end

  describe '#to_h and template structure' do
    it 'generates valid template header, parameters, resources, and outputs for minimal application' do
      result = described_class.compile(minimal_application)

      expect(result['AWSTemplateFormatVersion']).to eq('2010-09-09')
      expect(result['Description']).to include('simple-service - dev')
      expect(result['Parameters']).to have_key('ArtifactBucket')

      resources = result['Resources']
      expect(resources).to have_key('WorkerFunctionRole')
      expect(resources).to have_key('WorkerFunctionLogGroup')
      expect(resources).to have_key('WorkerFunction')

      outputs = result['Outputs']
      expect(outputs).to have_key('ApplicationName')
      expect(outputs).to have_key('ApplicationStage')
      expect(outputs).to have_key('WorkerFunctionArn')
      expect(outputs).to have_key('WorkerFunctionName')
    end

    it 'compiles full application with layer, schedule, queue, and correct DependsOn' do
      result = described_class.compile(full_application)

      resources = result['Resources']
      # Layers
      expect(resources).to have_key('RuntimeGemsLayerVersion')
      expect(resources['RuntimeGemsLayerVersion']['Type']).to eq('AWS::Lambda::LayerVersion')

      # SQS Queue (auto-discovered from schedule dlq)
      expect(resources).to have_key('NightlyDlqQueue')
      expect(resources['NightlyDlqQueue']['Type']).to eq('AWS::SQS::Queue')

      # Function Role & LogGroup & Function
      expect(resources).to have_key('ConvertFunctionRole')
      expect(resources).to have_key('ConvertFunctionLogGroup')
      expect(resources).to have_key('ConvertFunction')

      fn_resource = resources['ConvertFunction']
      expect(fn_resource['DependsOn']).to eq(%w[ConvertFunctionLogGroup RuntimeGemsLayerVersion])

      # Schedule & Schedule Role
      expect(resources).to have_key('NightlySyncScheduleRole')
      expect(resources).to have_key('NightlySyncSchedule')

      # Outputs
      outputs = result['Outputs']
      expect(outputs).to have_key('ConvertFunctionArn')
      expect(outputs).to have_key('ConvertFunctionName')
      expect(outputs).to have_key('RuntimeGemsLayerVersionArn')
      expect(outputs).to have_key('NightlySyncScheduleArn')
    end

    it 'allows custom parameters via parameters option' do
      result = described_class.compile(
        minimal_application,
        parameters: {
          'CustomVpcId' => { 'Type' => 'AWS::EC2::VPC::Id', 'Description' => 'Target VPC' }
        }
      )

      params = result['Parameters']
      expect(params).to have_key('ArtifactBucket')
      expect(params).to have_key('CustomVpcId')
      expect(params['CustomVpcId']['Type']).to eq('AWS::EC2::VPC::Id')
    end
  end

  describe '#generate and file writing' do
    it 'writes valid template YAML to destination file' do
      Dir.mktmpdir do |dir|
        target_path = File.join(dir, 'build', 'template.yml')
        res = described_class.generate(minimal_application, output_path: target_path)

        expect(File.exist?(target_path)).to be true
        content = File.read(target_path)
        loaded = YAML.safe_load(content)

        expect(loaded['AWSTemplateFormatVersion']).to eq('2010-09-09')
        expect(loaded['Resources']).to have_key('WorkerFunction')
        expect(res).to be_a(Hash)
      end
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'produces deterministic YAML across multiple invocations' do
      yaml1 = described_class.to_yaml(full_application)
      yaml2 = described_class.to_yaml(full_application)

      expect(yaml1).to eq(yaml2)
    end

    it 'guarantees alphabetical key ordering for all sections' do
      result = described_class.compile(full_application)

      expect(result.keys).to eq(%w[AWSTemplateFormatVersion Description Parameters Resources Outputs])
      expect(result['Parameters'].keys).to eq(result['Parameters'].keys.sort)
      expect(result['Resources'].keys).to eq(result['Resources'].keys.sort)
      expect(result['Outputs'].keys).to eq(result['Outputs'].keys.sort)
    end
  end

  describe 'CloudFormation module-level shortcuts' do
    it 'delegates compile, to_yaml, and generate to TemplateCompiler' do
      hash_res = Veltrunode::Compiler::CloudFormation.compile(minimal_application)
      yaml_res = Veltrunode::Compiler::CloudFormation.to_yaml(minimal_application)

      expect(hash_res).to have_key('Resources')
      expect(yaml_res).to include('AWSTemplateFormatVersion')
    end
  end

  describe 'Golden Test with parsed Veltrunodefile' do
    let(:veltrunodefile_code) do
      <<~RUBY
        Veltrunode.application "doc-converter" do
          aws region: "ap-northeast-1"
          runtime ruby: "3.4", architecture: :arm64

          defaults do
            logs retention_days: 30
          end

          layer :runtime_gems do
            bundle lockfile: "Gemfile.lock"
            build_on :amazon_linux_2023
            retain latest: 5
          end

          function :convert do
            handler "functions/convert.handler"
            memory 2048
            timeout 300
            attach_layer :runtime_gems
          end

          schedule :daily do
            target :convert
            cron "0 12 * * ? *"
            dead_letter_queue arn: "arn:aws:sqs:ap-northeast-1:123456789012:my-dlq"
          end
        end
      RUBY
    end

    it 'generates syntactically valid and deterministic CloudFormation YAML for DSL application' do
      app = Veltrunode.parse(veltrunodefile_code)
      yaml_output = described_class.to_yaml(app)

      parsed = YAML.safe_load(yaml_output)
      expect(parsed['AWSTemplateFormatVersion']).to eq('2010-09-09')
      expect(parsed['Resources'].keys).to eq(%w[
                                               ConvertFunction
                                               ConvertFunctionLogGroup
                                               ConvertFunctionRole
                                               DailySchedule
                                               DailyScheduleRole
                                               RuntimeGemsLayerVersion
                                             ])
      expect(parsed['Outputs'].keys).to eq(%w[
                                             ApplicationName
                                             ApplicationStage
                                             ConvertFunctionArn
                                             ConvertFunctionName
                                             DailyScheduleArn
                                             RuntimeGemsLayerVersionArn
                                           ])
    end
  end
end
