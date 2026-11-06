# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function'
require 'veltrunode/compiler/cloudformation/function_url_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::FunctionUrlCompiler do
  describe '.compile' do
    it 'generates AWS::Lambda::Url and public AWS::Lambda::Permission when auth_type is :none' do
      fn = Veltrunode::Model::Function.new(
        :webhook,
        handler: 'webhook.handler',
        runtime: 'ruby3.3',
        function_url: {
          auth_type: :none,
          cors: {
            allow_origins: ['https://example.com'],
            allow_methods: %w[POST OPTIONS],
            allow_headers: %w[Content-Type X-Signature],
            max_age: 86_400
          }
        }
      )

      resources = described_class.compile(fn)

      url_res = resources['WebhookFunctionUrl']
      expect(url_res).not_to be_nil
      expect(url_res['Type']).to eq('AWS::Lambda::Url')
      expect(url_res['Properties']).to eq(
        'AuthType' => 'NONE',
        'Cors' => {
          'AllowHeaders' => %w[Content-Type X-Signature],
          'AllowMethods' => %w[POST OPTIONS],
          'AllowOrigins' => ['https://example.com'],
          'MaxAge' => 86_400
        },
        'TargetFunctionArn' => { 'Fn::GetAtt' => %w[WebhookFunction Arn] }
      )

      perm_res = resources['WebhookFunctionUrlPermission']
      expect(perm_res).not_to be_nil
      expect(perm_res['Type']).to eq('AWS::Lambda::Permission')
      expect(perm_res['Properties']).to eq(
        'Action' => 'lambda:InvokeFunctionUrl',
        'FunctionName' => { 'Fn::GetAtt' => %w[WebhookFunction Arn] },
        'FunctionUrlAuthType' => 'NONE',
        'Principal' => '*'
      )
    end

    it 'generates AWS::Lambda::Url without public AWS::Lambda::Permission when auth_type is :aws_iam' do
      fn = Veltrunode::Model::Function.new(
        :internal_service,
        handler: 'internal.handler',
        runtime: 'ruby3.3',
        function_url: {
          auth_type: :aws_iam,
          invoke_mode: :response_stream
        }
      )

      resources = described_class.compile(fn)

      url_res = resources['InternalServiceFunctionUrl']
      expect(url_res).not_to be_nil
      expect(url_res['Type']).to eq('AWS::Lambda::Url')
      expect(url_res['Properties']).to eq(
        'AuthType' => 'AWS_IAM',
        'InvokeMode' => 'RESPONSE_STREAM',
        'TargetFunctionArn' => { 'Fn::GetAtt' => %w[InternalServiceFunction Arn] }
      )

      expect(resources).not_to have_key('InternalServiceFunctionUrlPermission')
    end
  end
end
