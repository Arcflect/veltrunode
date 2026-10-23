# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function'
require 'veltrunode/compiler/cloudformation/function_compiler'
require 'veltrunode/compiler/cloudformation/role_compiler'
require 'veltrunode/compiler/cloudformation/lambda_insights'

RSpec.describe 'Lambda Insights Compiler support' do
  let(:insights_policy_arn) do
    'arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy'
  end

  describe 'LambdaInsights module' do
    it 'returns layer ARN helper for specific regions and architectures' do
      arn_x86 = Veltrunode::Compiler::CloudFormation::LambdaInsights.layer_arn_for(
        region: 'ap-northeast-1',
        architecture: :x86_64
      )
      expect(arn_x86).to eq('arn:aws:lambda:ap-northeast-1:580247275435:layer:LambdaInsightsExtension:53')

      arn_arm = Veltrunode::Compiler::CloudFormation::LambdaInsights.layer_arn_for(
        region: 'us-west-2',
        architecture: :arm64
      )
      expect(arn_arm).to eq('arn:aws:lambda:us-west-2:580247275435:layer:LambdaInsightsExtension-Arm64:31')

      arn_cn = Veltrunode::Compiler::CloudFormation::LambdaInsights.layer_arn_for(
        region: 'cn-north-1',
        architecture: :x86_64
      )
      expect(arn_cn).to eq('arn:aws-cn:lambda:cn-north-1:018784642996:layer:LambdaInsightsExtension:53')

      arn_gov = Veltrunode::Compiler::CloudFormation::LambdaInsights.layer_arn_for(
        region: 'us-gov-west-1',
        architecture: :arm64
      )
      expect(arn_gov).to eq('arn:aws-us-gov:lambda:us-gov-west-1:519776269227:layer:LambdaInsightsExtension-Arm64:31')
    end
  end

  describe 'FunctionCompiler with Lambda Insights' do
    it 'attaches Lambda Insights layer for default x86_64 architecture' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['ApiFunction']['Properties']

      expect(props).to have_key('Layers')
      expected_layer = { 'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:580247275435:layer:LambdaInsightsExtension:53' }
      expect(props['Layers']).to include(expected_layer)
    end

    it 'attaches Lambda Insights Arm64 layer for arm64 architecture' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'worker.handler',
        runtime: 'python3.12',
        architecture: :arm64,
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['WorkerFunction']['Properties']

      expect(props).to have_key('Layers')
      expected_layer = {
        'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:580247275435:layer:LambdaInsightsExtension-Arm64:31'
      }
      expect(props['Layers']).to include(expected_layer)
    end

    it 'attaches specific version when configured' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'worker.handler',
        runtime: 'ruby3.3',
        insights: { version: 45 }
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['WorkerFunction']['Properties']

      expected_layer = { 'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:580247275435:layer:LambdaInsightsExtension:45' }
      expect(props['Layers']).to include(expected_layer)
    end

    it 'uses custom layer ARN when provided' do
      custom_layer = 'arn:aws:lambda:ap-northeast-1:123456789012:layer:my-insights:1'
      fn = Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'worker.handler',
        runtime: 'ruby3.3',
        insights: { layer_arn: custom_layer }
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['WorkerFunction']['Properties']

      expect(props['Layers']).to include(custom_layer)
    end

    it 'resolves china partition and account when region is cn-*' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn, context: { region: 'cn-north-1' })
      props = res['ApiFunction']['Properties']

      expected_layer = {
        'Fn::Sub' => 'arn:aws-cn:lambda:${AWS::Region}:018784642996:layer:LambdaInsightsExtension:53'
      }
      expect(props['Layers']).to include(expected_layer)
    end

    it 'resolves us-gov partition and account when region is us-gov-*' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        architecture: :arm64,
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn, context: { region: 'us-gov-east-1' })
      props = res['ApiFunction']['Properties']

      expected_layer = {
        'Fn::Sub' => 'arn:aws-us-gov:lambda:${AWS::Region}:519776269227:layer:LambdaInsightsExtension-Arm64:31'
      }
      expect(props['Layers']).to include(expected_layer)
    end

    it 'does not attach layer when insights is false' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        insights: false
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['ApiFunction']['Properties']

      expect(props['Layers']).to be_nil
    end
  end

  describe 'RoleCompiler with Lambda Insights' do
    it 'automatically attaches CloudWatchLambdaInsightsExecutionRolePolicy when insights is enabled' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props).to have_key('ManagedPolicyArns')
      expect(props['ManagedPolicyArns']).to include(insights_policy_arn)
    end

    it 'does not attach CloudWatchLambdaInsightsExecutionRolePolicy when insights is false' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        insights: false
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props['ManagedPolicyArns']).to be_nil
    end

    it 'attaches both X-Ray and Insights policies when both are enabled' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        tracing: :active,
        insights: true
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props['ManagedPolicyArns']).to eq([
                                                 'arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess',
                                                 insights_policy_arn
                                               ])
    end
  end
end
