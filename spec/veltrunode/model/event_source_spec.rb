# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/event_source'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Model::EventSource do
  describe '#initialize' do
    it 'creates a valid SQS event source with all parameters' do
      source = described_class.new(
        type: :sqs,
        queue: 'arn:aws:sqs:ap-northeast-1:123456789012:my-queue',
        batch_size: 10,
        maximum_batching_window_in_seconds: 5,
        report_batch_item_failures: true,
        enabled: true
      )

      expect(source.sqs?).to be true
      expect(source.type).to eq(:sqs)
      expect(source.queue).to eq('arn:aws:sqs:ap-northeast-1:123456789012:my-queue')
      expect(source.batch_size).to eq(10)
      expect(source.maximum_batching_window_in_seconds).to eq(5)
      expect(source.report_batch_item_failures?).to be true
      expect(source.enabled?).to be true
    end

    it 'supports symbolic queue names' do
      source = described_class.new(type: :sqs, queue: :orders_queue)
      expect(source.queue).to eq(:orders_queue)
      expect(source.queue_identifier).to eq('orders_queue')
    end

    it 'extracts queue_identifier from arn' do
      source = described_class.new(queue: 'arn:aws:sqs:us-east-1:123456789012:payment-jobs')
      expect(source.queue_identifier).to eq('payment-jobs')
    end

    it 'raises ArgumentError if queue is missing' do
      expect { described_class.new(type: :sqs, queue: nil) }
        .to raise_error(ArgumentError, /Queue must be specified/)
      expect { described_class.new(type: :sqs, queue: '') }
        .to raise_error(ArgumentError, /Queue must be specified/)
    end

    it 'raises ArgumentError if batch_size is invalid' do
      expect { described_class.new(queue: 'q', batch_size: 0) }
        .to raise_error(ArgumentError, /Batch size must be between 1 and 10000/)
      expect { described_class.new(queue: 'q', batch_size: 10_001) }
        .to raise_error(ArgumentError, /Batch size must be between 1 and 10000/)
    end

    it 'raises ArgumentError if maximum_batching_window_in_seconds is invalid' do
      expect { described_class.new(queue: 'q', maximum_batching_window_in_seconds: -1) }
        .to raise_error(ArgumentError, /Maximum batching window must be between 0 and 300/)
      expect { described_class.new(queue: 'q', maximum_batching_window_in_seconds: 301) }
        .to raise_error(ArgumentError, /Maximum batching window must be between 0 and 300/)
    end

    it 'raises ArgumentError if type is unsupported' do
      expect { described_class.new(type: :kinesis, queue: 'stream') }
        .to raise_error(ArgumentError, /Unsupported event source type/)
    end
  end

  describe '#to_h' do
    it 'serializes event source attributes' do
      source = described_class.new(
        queue: 'my-queue',
        batch_size: 20,
        maximum_batching_window_in_seconds: 10,
        report_batch_item_failures: true
      )

      hash = source.to_h
      expect(hash['type']).to eq('sqs')
      expect(hash['queue']).to eq('my-queue')
      expect(hash['batch_size']).to eq(20)
      expect(hash['maximum_batching_window_in_seconds']).to eq(10)
      expect(hash['report_batch_item_failures']).to be true
      expect(hash['enabled']).to be true
    end
  end

  describe 'Function integration' do
    it 'accepts event_sources array in Function' do
      source = described_class.new(queue: 'jobs')
      fn = Veltrunode::Model::Function.new(
        'worker',
        handler: 'worker.handler',
        runtime: 'ruby3.3',
        event_sources: [source]
      )

      expect(fn.event_sources?).to be true
      expect(fn.event_sources.size).to eq(1)
      expect(fn.event_sources.first.queue).to eq('jobs')
    end
  end
end
