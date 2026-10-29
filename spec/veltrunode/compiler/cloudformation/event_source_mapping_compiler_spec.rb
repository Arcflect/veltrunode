# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/event_source_mapping_compiler'
require 'veltrunode/model/function'
require 'veltrunode/model/event_source'

RSpec.describe Veltrunode::Compiler::CloudFormation::EventSourceMappingCompiler do
  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'worker.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.compile' do
    it 'compiles basic SQS event source mapping with symbol queue' do
      source = Veltrunode::Model::EventSource.new(
        queue: :orders,
        batch_size: 10,
        maximum_batching_window_in_seconds: 30,
        report_batch_item_failures: true
      )

      res = described_class.compile(function, source)

      expect(res).to eq(
        'WorkerFunctionOrdersEventSourceMapping' => {
          'Type' => 'AWS::Lambda::EventSourceMapping',
          'Properties' => {
            'BatchSize' => 10,
            'Enabled' => true,
            'EventSourceArn' => { 'Fn::GetAtt' => %w[OrdersQueue Arn] },
            'FunctionName' => { 'Fn::GetAtt' => %w[WorkerFunction Arn] },
            'FunctionResponseTypes' => ['ReportBatchItemFailures'],
            'MaximumBatchingWindowInSeconds' => 30
          }
        }
      )
    end

    it 'compiles SQS event source mapping with ARN queue' do
      source = Veltrunode::Model::EventSource.new(
        queue: 'arn:aws:sqs:ap-northeast-1:123456789012:imported-queue',
        batch_size: 5,
        report_batch_item_failures: false,
        enabled: false
      )

      res = described_class.compile(function, source)

      expect(res).to eq(
        'WorkerFunctionImportedQueueEventSourceMapping' => {
          'Type' => 'AWS::Lambda::EventSourceMapping',
          'Properties' => {
            'BatchSize' => 5,
            'Enabled' => false,
            'EventSourceArn' => 'arn:aws:sqs:ap-northeast-1:123456789012:imported-queue',
            'FunctionName' => { 'Fn::GetAtt' => %w[WorkerFunction Arn] }
          }
        }
      )
    end

    it 'omits optional properties when not specified' do
      source = Veltrunode::Model::EventSource.new(queue: :notifications)

      res = described_class.compile(function, source)
      props = res['WorkerFunctionNotificationsEventSourceMapping']['Properties']

      expect(props).not_to have_key('BatchSize')
      expect(props['Enabled']).to be(true)
      expect(props).not_to have_key('MaximumBatchingWindowInSeconds')
      expect(props).not_to have_key('FunctionResponseTypes')
    end
  end

  describe '.to_yaml' do
    it 'produces valid YAML string' do
      source = Veltrunode::Model::EventSource.new(
        queue: :orders,
        batch_size: 10,
        report_batch_item_failures: true
      )

      yaml_str = described_class.to_yaml(function, source)
      parsed = YAML.safe_load(yaml_str)

      expect(parsed).to have_key('WorkerFunctionOrdersEventSourceMapping')
      mapping = parsed['WorkerFunctionOrdersEventSourceMapping']
      expect(mapping['Type']).to eq('AWS::Lambda::EventSourceMapping')
      expect(mapping['Properties']['FunctionResponseTypes']).to eq(['ReportBatchItemFailures'])
    end
  end
end
