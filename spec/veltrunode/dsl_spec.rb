# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::DSL do
  before do
    Veltrunode.reset!
  end

  let(:sample_veltrunodefile_content) do
    <<~RUBY
      Veltrunode.application "document-converter" do
        aws region: "ap-northeast-1", account: "123456789012"
        runtime ruby: "3.4", architecture: :arm64

        defaults do
          logs retention_days: 30
          tags system: "document-converter", managed_by: "veltrunode"
        end

        layer :runtime_gems do
          bundle lockfile: "Gemfile.lock", without: %i[development test]
          include_gems %w[aws-sdk-s3 nokogiri]
          build_on :amazon_linux_2023
          retain latest: 5
        end

        efs_mount :workspace do
          existing_access_point arn: "arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0"
          local_path "/mnt/workspace"
          expect_posix uid: 1000, gid: 1000
        end

        function :convert do
          handler "functions/convert.handler"
          memory 4096
          timeout 900
          ephemeral_storage 4096
          attach_layer :runtime_gems
          mount :workspace
          permit do
            read_from_s3 bucket: ref(:input_bucket)
            write_to_s3 bucket: ref(:output_bucket)
          end
        end

        schedule :nightly do
          target :convert
          cron "0 1 * * ? *", timezone: "Asia/Tokyo"
          input source: "nightly"
          retry maximum_attempts: 2, maximum_event_age: 7200
          dead_letter_queue arn: "arn:aws:sqs:ap-northeast-1:123456789012:dlq"
        end
      end
    RUBY
  end

  describe '.parse' do
    it 'parses sample Veltrunodefile code and creates a typed Application model' do
      app = Veltrunode.parse(sample_veltrunodefile_content)

      expect(app).to be_a(Veltrunode::Model::Application)
      expect(app.name).to eq('document-converter')
      expect(app.region).to eq('ap-northeast-1')
      expect(app.account_constraint).to eq('123456789012')
      expect(app.tags).to eq({ system: 'document-converter', managed_by: 'veltrunode' })

      # Layer validation
      expect(app.layers.size).to eq(1)
      layer = app.layers.first
      expect(layer.name).to eq('runtime_gems')
      expect(layer.build_environment['lockfile']).to eq('Gemfile.lock')
      expect(layer.build_environment['without']).to eq(%w[development test])
      expect(layer.build_environment['include_gems']).to eq(%w[aws-sdk-s3 nokogiri])
      expect(layer.retention_policy).to eq({ latest: 5 })

      # EfsMount validation
      expect(app.mounts.size).to eq(1)
      mount = app.mounts.first
      expect(mount.symbolic_name).to eq('workspace')
      expect(mount.local_path).to eq('/mnt/workspace')
      expect(mount.posix_expectations).to eq({ 'uid' => 1000, 'gid' => 1000 })

      # Function validation
      expect(app.functions.size).to eq(1)
      fn = app.functions.first
      expect(fn.logical_name).to eq('convert')
      expect(fn.handler).to eq('functions/convert.handler')
      expect(fn.memory).to eq(4096)
      expect(fn.timeout).to eq(900)
      expect(fn.ephemeral_storage).to eq(4096)
      expect(fn.layers).to eq(['runtime_gems'])
      expect(fn.mounts).to eq(['workspace'])
      expect(fn.iam_capabilities.size).to eq(2)
      expect(fn.iam_capabilities.map(&:type)).to eq(%i[read_from_s3 write_to_s3])

      # Schedule validation
      expect(app.schedules.size).to eq(1)
      sched = app.schedules.first
      expect(sched.name).to eq('nightly')
      expect(sched.target_function).to eq('convert')
      expect(sched.expression_type).to eq(:cron)
      expect(sched.expression).to eq('0 1 * * ? *')
      expect(sched.timezone).to eq('Asia/Tokyo')
      expect(sched.retry_policy['maximum_attempts']).to eq(2)
      expect(sched.dlq).to eq('arn:aws:sqs:ap-northeast-1:123456789012:dlq')
    end
  end

  describe 'undefined method handling' do
    it 'raises ValidationError with VLT-DSL-001 diagnostic when an undefined method is called' do
      invalid_code = <<~RUBY
        Veltrunode.application "invalid-app" do
          aws region: "ap-northeast-1"
          unknown_dsl_method "some_value"
        end
      RUBY

      expect { Veltrunode.parse(invalid_code) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-DSL-001')
        }
    end
  end

  describe 'env and SecretValue helpers' do
    before do
      ENV['TEST_ENV_VAR'] = 'my_secret_token'
    end

    after do
      ENV.delete('TEST_ENV_VAR')
    end

    it 'reads environment variables and masks secrets in inspect' do
      code = <<~RUBY
        Veltrunode.application "env-app" do
          aws region: "ap-northeast-1"
          function :test_fn do
            handler "fn.handler"
            environment SECRET: env("TEST_ENV_VAR", secret: true)
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      fn = app.functions.first
      secret_val = fn.environment['SECRET']

      expect(secret_val).to be_a(Veltrunode::DSL::SecretValue)
      expect(secret_val.to_s).to eq('my_secret_token')
      expect(secret_val.inspect).to eq('[FILTERED]')
    end
  end

  describe 'ref helper' do
    it 'creates a Reference object' do
      ref_obj = Veltrunode::DSL::Reference.new(:input_bucket)
      expect(ref_obj.name).to eq(:input_bucket)
      expect(ref_obj.inspect).to eq('ref(:input_bucket)')
    end
  end
end
