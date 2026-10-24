# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/compiler/cloudformation/event_invoke_config_compiler'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Compiler::CloudFormation::EventInvokeConfigCompiler do
  describe '.compile' do
    it 'compiles basic retry and age config' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'app.handler',
        runtime: 'nodejs20.x',
        async_invoke: { max_retries: 2, max_age: 3600 }
      )

      res = described_class.compile(fn)

      expect(res).to eq(
        'WorkerFunctionEventInvokeConfig' => {
          'Type' => 'AWS::Lambda::EventInvokeConfig',
          'Properties' => {
            'FunctionName' => { 'Ref' => 'WorkerFunction' },
            'MaximumEventAgeInSeconds' => 3600,
            'MaximumRetryAttempts' => 2,
            'Qualifier' => '$LATEST'
          }
        }
      )
    end

    it 'compiles destination configuration' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'notifier',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        async_invoke: {
          max_retries: 1,
          on_success: 'arn:aws:sqs:ap-northeast-1:123456789012:success-queue',
          on_failure: 'arn:aws:sns:ap-northeast-1:123456789012:failure-topic'
        }
      )

      res = described_class.compile(fn)

      expect(res['NotifierFunctionEventInvokeConfig']['Properties']['DestinationConfig']).to eq(
        'OnFailure' => {
          'Destination' => 'arn:aws:sns:ap-northeast-1:123456789012:failure-topic'
        },
        'OnSuccess' => {
          'Destination' => 'arn:aws:sqs:ap-northeast-1:123456789012:success-queue'
        }
      )
    end

    it 'returns empty hash when function has no async_invoke' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'simple',
        handler: 'app.handler',
        runtime: 'ruby3.3'
      )

      expect(described_class.compile(fn)).to eq({})
    end
  end
end
