# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe Veltrunode::Compiler::CloudFormation::RoleCompiler do
  let(:minimal_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'convert',
      handler: 'convert.handler',
      runtime: 'ruby3.3'
    )
  end

  let(:full_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_handler',
      handler: 'functions/api.handler',
      runtime: 'ruby3.3',
      iam_capabilities: [
        {
          type: :read_from_s3,
          params: { bucket: 'my-data-bucket', prefix: 'incoming/' }
        }
      ],
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

  let(:minimal_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'daily_sync',
      target_function: 'convert',
      expression_type: :cron,
      expression: '0 0 * * ? *'
    )
  end

  let(:arn_target_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'external_job',
      target_function: 'arn:aws:lambda:ap-northeast-1:123456789012:function:custom_worker',
      expression_type: :rate,
      expression: 'rate(1 hour)'
    )
  end

  describe '.logical_id_for_function and .logical_id_for_schedule' do
    it 'generates stable PascalCase logical IDs for Lambda execution roles' do
      expect(described_class.logical_id_for_function('convert')).to eq('ConvertFunctionRole')
      expect(described_class.logical_id_for_function('api_handler')).to eq('ApiHandlerFunctionRole')
    end

    it 'generates stable PascalCase logical IDs for Scheduler invocation roles' do
      expect(described_class.logical_id_for_schedule('daily_sync')).to eq('DailySyncScheduleRole')
      expect(described_class.logical_id_for_schedule('external_job')).to eq('ExternalJobScheduleRole')
    end
  end

  describe '#to_h and properties for Lambda Execution Role' do
    it 'compiles a minimal Lambda execution role with lambda.amazonaws.com AssumeRole policy and CloudWatch Logs' do
      result = described_class.compile_lambda_role(minimal_function)

      expect(result).to have_key('ConvertFunctionRole')

      resource = result['ConvertFunctionRole']
      expect(resource['Type']).to eq('AWS::IAM::Role')

      props = resource['Properties']
      assume_stmt = props['AssumeRolePolicyDocument']['Statement'].first
      expect(assume_stmt['Principal']).to eq({ 'Service' => 'lambda.amazonaws.com' })
      expect(assume_stmt['Action']).to eq('sts:AssumeRole')

      policies = props['Policies']
      expect(policies.size).to eq(1)

      policy_stmts = policies.first['PolicyDocument']['Statement']
      expect(policy_stmts.size).to eq(1)

      cw_stmt = policy_stmts.first
      expect(cw_stmt['Action']).to eq(%w[logs:CreateLogStream logs:PutLogEvents])
      expect(cw_stmt['Resource']).to eq([{ 'Fn::GetAtt' => %w[ConvertFunctionLogGroup Arn] }])
    end

    it 'compiles a full Lambda execution role with IAM capabilities and EFS mount permissions' do
      result = described_class.compile_lambda_role(full_function)

      expect(result).to have_key('ApiHandlerFunctionRole')

      props = result['ApiHandlerFunctionRole']['Properties']
      policy_stmts = props['Policies'].first['PolicyDocument']['Statement']

      # Statement 1: CloudWatch Logs
      expect(policy_stmts[0]['Action']).to eq(%w[logs:CreateLogStream logs:PutLogEvents])
      expect(policy_stmts[0]['Resource']).to eq([{ 'Fn::GetAtt' => %w[ApiHandlerFunctionLogGroup Arn] }])

      # Statement 2: Capability (read_from_s3)
      expect(policy_stmts[1]['Action']).to eq(%w[s3:GetObject s3:ListBucket])
      expect(policy_stmts[1]['Resource']).to eq([
                                                  'arn:aws:s3:::my-data-bucket',
                                                  'arn:aws:s3:::my-data-bucket/incoming/*'
                                                ])

      # Statement 3: EFS mount
      expect(policy_stmts[2]['Action']).to eq(%w[elasticfilesystem:ClientMount elasticfilesystem:ClientWrite])
      expect(policy_stmts[2]['Resource']).to eq([
                                                  'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:' \
                                                  'access-point/fsap-1234567890abcdef0'
                                                ])
    end
  end

  describe '#to_h and properties for Scheduler Invocation Role' do
    it 'compiles a Scheduler invocation role restricted to scheduler.amazonaws.com and lambda:InvokeFunction' do
      result = described_class.compile_scheduler_role(minimal_schedule)

      expect(result).to have_key('DailySyncScheduleRole')

      resource = result['DailySyncScheduleRole']
      expect(resource['Type']).to eq('AWS::IAM::Role')

      props = resource['Properties']
      assume_stmt = props['AssumeRolePolicyDocument']['Statement'].first
      expect(assume_stmt['Principal']).to eq({ 'Service' => 'scheduler.amazonaws.com' })
      expect(assume_stmt['Action']).to eq('sts:AssumeRole')

      policies = props['Policies']
      policy_stmts = policies.first['PolicyDocument']['Statement']
      expect(policy_stmts.size).to eq(1)

      invoke_stmt = policy_stmts.first
      expect(invoke_stmt['Action']).to eq(['lambda:InvokeFunction'])
      expect(invoke_stmt['Resource']).to eq([{ 'Fn::GetAtt' => %w[ConvertFunction Arn] }])
    end

    it 'uses explicit target function ARN when passed an ARN string' do
      result = described_class.compile_scheduler_role(arn_target_schedule)
      policy_stmts = result['ExternalJobScheduleRole']['Properties']['Policies'].first['PolicyDocument']['Statement']

      expect(policy_stmts.first['Resource']).to eq(['arn:aws:lambda:ap-northeast-1:123456789012:function:custom_worker'])
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile_lambda_role(full_function)
      resource_keys = result['ApiHandlerFunctionRole'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['ApiHandlerFunctionRole']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)
    end

    it 'produces deterministic YAML output across multiple compilations' do
      yaml1 = described_class.to_yaml_lambda_role(full_function)
      yaml2 = described_class.to_yaml_lambda_role(full_function)

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches the expected golden YAML output for full Lambda execution role' do
      expected_yaml = <<~YAML
        ---
        ApiHandlerFunctionRole:
          Properties:
            AssumeRolePolicyDocument:
              Statement:
              - Action: sts:AssumeRole
                Effect: Allow
                Principal:
                  Service: lambda.amazonaws.com
              Version: '2012-10-17'
            Policies:
            - PolicyDocument:
                Statement:
                - Action:
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                  Effect: Allow
                  Resource:
                  - Fn::GetAtt:
                    - ApiHandlerFunctionLogGroup
                    - Arn
                - Action:
                  - s3:GetObject
                  - s3:ListBucket
                  Effect: Allow
                  Resource:
                  - arn:aws:s3:::my-data-bucket
                  - arn:aws:s3:::my-data-bucket/incoming/*
                - Action:
                  - elasticfilesystem:ClientMount
                  - elasticfilesystem:ClientWrite
                  Effect: Allow
                  Resource:
                  - arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0
                Version: '2012-10-17'
              PolicyName: ApiHandlerFunctionRolePolicy
          Type: AWS::IAM::Role
      YAML

      generated_yaml = described_class.to_yaml_lambda_role(full_function)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end

    it 'matches the expected golden YAML output for Scheduler invocation role' do
      expected_yaml = <<~YAML
        ---
        DailySyncScheduleRole:
          Properties:
            AssumeRolePolicyDocument:
              Statement:
              - Action: sts:AssumeRole
                Effect: Allow
                Principal:
                  Service: scheduler.amazonaws.com
              Version: '2012-10-17'
            Policies:
            - PolicyDocument:
                Statement:
                - Action:
                  - lambda:InvokeFunction
                  Effect: Allow
                  Resource:
                  - Fn::GetAtt:
                    - ConvertFunction
                    - Arn
                Version: '2012-10-17'
              PolicyName: DailySyncScheduleRolePolicy
          Type: AWS::IAM::Role
      YAML

      generated_yaml = described_class.to_yaml_scheduler_role(minimal_schedule)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
