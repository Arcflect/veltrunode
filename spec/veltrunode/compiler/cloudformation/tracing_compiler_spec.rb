# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function'
require 'veltrunode/compiler/cloudformation/function_compiler'
require 'veltrunode/compiler/cloudformation/role_compiler'

RSpec.describe 'Tracing CloudFormation Compilers' do
  describe 'FunctionCompiler with tracing' do
    it 'compiles TracingConfig for active tracing' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'ruby3.3',
        tracing: :active
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['ApiFunction']['Properties']

      expect(props).to have_key('TracingConfig')
      expect(props['TracingConfig']).to eq({ 'Mode' => 'Active' })
      expect(props).not_to have_key('Layers')
    end

    it 'compiles TracingConfig for pass_through tracing' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'ruby3.3',
        tracing: :pass_through
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['ApiFunction']['Properties']

      expect(props).to have_key('TracingConfig')
      expect(props['TracingConfig']).to eq({ 'Mode' => 'PassThrough' })
    end

    it 'attaches ADOT layer and configures AWS_LAMBDA_EXEC_WRAPPER for nodejs' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        architecture: :arm64,
        tracing: :adot
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['ApiFunction']['Properties']

      expect(props['TracingConfig']).to eq({ 'Mode' => 'Active' })
      expect(props).to have_key('Layers')
      expected_layer = { 'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:901920570468:layer:aws-otel-nodejs-arm64-ver-1-18-0:1' }
      expect(props['Layers']).to include(expected_layer)

      expect(props).to have_key('Environment')
      expect(props['Environment']['Variables']['AWS_LAMBDA_EXEC_WRAPPER']).to eq('/opt/otel-instrument')
    end

    it 'uses custom ADOT layer ARN when provided' do
      custom_layer = 'arn:aws:lambda:ap-northeast-1:123456789012:layer:my-otel:1'
      fn = Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'worker.handler',
        runtime: 'python3.12',
        tracing: { mode: :active, adot: custom_layer }
      )

      res = Veltrunode::Compiler::CloudFormation::FunctionCompiler.compile(fn)
      props = res['WorkerFunction']['Properties']

      expect(props['TracingConfig']).to eq({ 'Mode' => 'Active' })
      expect(props['Layers']).to include(custom_layer)
    end
  end

  describe 'RoleCompiler with tracing' do
    it 'automatically attaches AWSXRayDaemonWriteAccess managed policy when tracing is active' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'ruby3.3',
        tracing: :active
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props).to have_key('ManagedPolicyArns')
      expect(props['ManagedPolicyArns']).to include('arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess')
    end

    it 'attaches AWSXRayDaemonWriteAccess when tracing is pass_through' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'ruby3.3',
        tracing: :pass_through
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props['ManagedPolicyArns']).to include('arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess')
    end

    it 'does not attach AWSXRayDaemonWriteAccess when tracing is not enabled' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'ruby3.3'
      )

      res = Veltrunode::Compiler::CloudFormation::RoleCompiler.compile_lambda_role(fn)
      props = res['ApiFunctionRole']['Properties']

      expect(props).not_to have_key('ManagedPolicyArns')
    end
  end
end
