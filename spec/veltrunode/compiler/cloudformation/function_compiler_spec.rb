# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe Veltrunode::Compiler::CloudFormation::FunctionCompiler do
  let(:full_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_handler',
      handler: 'functions/api.handler',
      runtime: 'ruby3.3',
      architecture: 'arm64',
      memory: 256,
      timeout: 10,
      ephemeral_storage: 512,
      environment: { 'LOG_LEVEL' => 'info', 'APP_ENV' => 'production' },
      vpc_reference: { security_group_ids: ['sg-12345'], subnet_ids: %w[subnet-abc subnet-xyz] },
      layers: ['gem_deps'],
      mounts: [
        Veltrunode::Model::EfsMount.new(
          symbolic_name: 'shared_storage',
          access_point_source:
            'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0',
          local_path: '/mnt/data'
        )
      ]
    )
  end

  let(:minimal_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'convert',
      handler: 'convert.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.logical_id_for' do
    it 'converts symbolic and string names to stable PascalCase Logical IDs ending with Function' do
      expect(described_class.logical_id_for(:convert)).to eq('ConvertFunction')
      expect(described_class.logical_id_for('convert')).to eq('ConvertFunction')
      expect(described_class.logical_id_for('api_handler')).to eq('ApiHandlerFunction')
      expect(described_class.logical_id_for('convert_function')).to eq('ConvertFunction')
      expect(described_class.logical_id_for('my_pdf_converter')).to eq('MyPdfConverterFunction')
    end
  end

  describe '#to_h and #properties' do
    it 'maps all Function attributes to AWS::Lambda::Function properties correctly' do
      compiler = described_class.new(full_function)
      result = compiler.to_h

      expect(result).to have_key('ApiHandlerFunction')

      resource = result['ApiHandlerFunction']
      expect(resource['Type']).to eq('AWS::Lambda::Function')

      props = resource['Properties']
      expect(props['FunctionName']).to eq('api_handler')
      expect(props['Handler']).to eq('functions/api.handler')
      expect(props['Runtime']).to eq('ruby3.3')
      expect(props['Architectures']).to eq(['arm64'])
      expect(props['MemorySize']).to eq(256)
      expect(props['Timeout']).to eq(10)
      expect(props['EphemeralStorage']).to eq({ 'Size' => 512 })
      expect(props['Environment']).to eq({ 'Variables' => { 'APP_ENV' => 'production', 'LOG_LEVEL' => 'info' } })
      expect(props['VpcConfig']).to eq({
                                         'SecurityGroupIds' => ['sg-12345'],
                                         'SubnetIds' => %w[subnet-abc subnet-xyz]
                                       })
      expect(props['Layers']).to eq([{ 'Ref' => 'GemDepsLayerVersion' }])
      expect(props['FileSystemConfigs']).to eq([
                                                 {
                                                   'Arn' => 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:' \
                                                            'access-point/fsap-1234567890abcdef0',
                                                   'LocalMountPath' => '/mnt/data'
                                                 }
                                               ])

      expect(props['Role']).to eq({ 'Fn::GetAtt' => %w[ApiHandlerFunctionRole Arn] })
      expect(props['Code']).to eq({ 'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
                                    'S3Key' => 'artifacts/functions/api_handler.zip' })
    end

    it 'compiles a minimal function with default role and code' do
      result = described_class.compile(minimal_function)

      expect(result).to have_key('ConvertFunction')
      props = result['ConvertFunction']['Properties']

      expect(props['FunctionName']).to eq('convert')
      expect(props['Handler']).to eq('convert.handler')
      expect(props['Runtime']).to eq('ruby3.3')
      expect(props['Architectures']).to eq(['x86_64'])
      expect(props['MemorySize']).to eq(128)
      expect(props['Timeout']).to eq(3)
      expect(props['EphemeralStorage']).to eq({ 'Size' => 512 })
      expect(props['Role']).to eq({ 'Fn::GetAtt' => %w[ConvertFunctionRole Arn] })
    end

    it 'allows overriding role and code parameters' do
      custom_role = 'arn:aws:iam::123456789012:role/custom-lambda-role'
      custom_code = { 'S3Bucket' => 'my-bucket', 'S3Key' => 'code.zip' }

      result = described_class.compile(minimal_function, role: custom_role, code: custom_code)
      props = result['ConvertFunction']['Properties']

      expect(props['Role']).to eq(custom_role)
      expect(props['Code']).to eq(custom_code)
    end

    it 'raises ValidationError when environment variables contain SecretValue' do
      secret_env_fn = Veltrunode::Model::Function.new(
        logical_name: 'sec_fn',
        handler: 'fn.handler',
        environment: { 'DB_PASS' => Veltrunode::DSL::SecretValue.new('secret_password') }
      )

      expect { described_class.compile(secret_env_fn) }
        .to raise_error(Veltrunode::ValidationError, /SecretValue cannot be embedded/)
    end

    it 'preserves Hash or Array intrinsic functions in environment variables' do
      intrinsic_fn = Veltrunode::Model::Function.new(
        logical_name: 'intrinsic_fn',
        handler: 'fn.handler',
        environment: { 'PARAM_VAL' => { 'Ref' => 'MyParam' } }
      )

      result = described_class.compile(intrinsic_fn)
      env_vars = result['IntrinsicFnFunction']['Properties']['Environment']['Variables']

      expect(env_vars['PARAM_VAL']).to eq({ 'Ref' => 'MyParam' })
    end

    it 'raises ValidationError when vpc_reference is a raw VPC ID string' do
      vpc_id_fn = Veltrunode::Model::Function.new(
        logical_name: 'vpc_id_fn',
        handler: 'fn.handler',
        vpc_reference: 'vpc-12345678'
      )

      expect { described_class.compile(vpc_id_fn) }
        .to raise_error(Veltrunode::ValidationError, /VPC IDs \(vpc-12345678\) are not supported/)
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(full_function)
      resource_keys = result['ApiHandlerFunction'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['ApiHandlerFunction']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)
    end

    it 'produces deterministic output across multiple compilations' do
      yaml1 = described_class.to_yaml(full_function)
      yaml2 = described_class.to_yaml(full_function)

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches the expected golden YAML output for full function' do
      expected_yaml = <<~YAML
        ---
        ApiHandlerFunction:
          Properties:
            Architectures:
            - arm64
            Code:
              S3Bucket:
                Ref: ArtifactBucket
              S3Key: artifacts/functions/api_handler.zip
            Environment:
              Variables:
                APP_ENV: production
                LOG_LEVEL: info
            EphemeralStorage:
              Size: 512
            FileSystemConfigs:
            - Arn: arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0
              LocalMountPath: "/mnt/data"
            FunctionName: api_handler
            Handler: functions/api.handler
            Layers:
            - Ref: GemDepsLayerVersion
            MemorySize: 256
            Role:
              Fn::GetAtt:
              - ApiHandlerFunctionRole
              - Arn
            Runtime: ruby3.3
            Timeout: 10
            VpcConfig:
              SecurityGroupIds:
              - sg-12345
              SubnetIds:
              - subnet-abc
              - subnet-xyz
          Type: AWS::Lambda::Function
      YAML

      generated_yaml = described_class.to_yaml(full_function)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
