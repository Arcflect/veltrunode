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

    it 'creates a valid SNS event source with topic ARN and filter_policy' do
      source = described_class.new(
        type: :sns,
        topic: 'arn:aws:sns:ap-northeast-1:123456789012:order-events',
        filter_policy: { event_type: %i[order_created order_cancelled] },
        filter_policy_scope: :message_attributes
      )

      expect(source.sns?).to be true
      expect(source.sqs?).to be false
      expect(source.type).to eq(:sns)
      expect(source.topic).to eq('arn:aws:sns:ap-northeast-1:123456789012:order-events')
      expect(source.topic_identifier).to eq('order-events')
      expect(source.source_identifier).to eq('order-events')
      expect(source.filter_policy).to eq('event_type' => %w[order_created order_cancelled])
      expect(source.filter_policy_scope).to eq('MessageAttributes')
      expect(source.enabled?).to be true
    end

    it 'infers SNS type when sns: or topic: is passed' do
      source = described_class.new(
        sns: :order_topic,
        filter_policy: { status: ['completed'] }
      )

      expect(source.sns?).to be true
      expect(source.topic).to eq(:order_topic)
      expect(source.topic_identifier).to eq('order_topic')
      expect(source.filter_policy).to eq('status' => ['completed'])
    end

    it 'supports nested hash in sns: option' do
      source = described_class.new(
        sns: {
          topic: 'arn:aws:sns:ap-northeast-1:123456789012:alerts',
          filter_policy: { severity: ['high'] },
          filter_policy_scope: 'MessageBody'
        }
      )

      expect(source.sns?).to be true
      expect(source.topic).to eq('arn:aws:sns:ap-northeast-1:123456789012:alerts')
      expect(source.filter_policy).to eq('severity' => ['high'])
      expect(source.filter_policy_scope).to eq('MessageBody')
    end

    it 'raises ArgumentError if topic is missing for SNS event source' do
      expect { described_class.new(type: :sns, topic: nil) }
        .to raise_error(ArgumentError, /Topic must be specified for SNS event source/)
      expect { described_class.new(type: :sns, topic: '   ') }
        .to raise_error(ArgumentError, /Topic must be specified for SNS event source/)
    end

    it 'raises ArgumentError if filter_policy is not a non-empty Hash' do
      expect { described_class.new(type: :sns, topic: :orders, filter_policy: 'invalid') }
        .to raise_error(ArgumentError, /Filter policy must be a Hash/)
      expect { described_class.new(type: :sns, topic: :orders, filter_policy: {}) }
        .to raise_error(ArgumentError, /Filter policy cannot be empty/)
    end

    it 'raises ArgumentError if filter_policy_scope is invalid' do
      expect { described_class.new(type: :sns, topic: :orders, filter_policy_scope: 'InvalidScope') }
        .to raise_error(ArgumentError, /Invalid filter_policy_scope/)
    end

    it 'creates a valid S3 event source with bucket, events, and filter' do
      source = described_class.new(
        type: :s3,
        bucket: :uploads,
        events: ['s3:ObjectCreated:*'],
        filter: { prefix: 'incoming/', suffix: '.pdf' }
      )

      expect(source.s3?).to be true
      expect(source.sqs?).to be false
      expect(source.sns?).to be false
      expect(source.type).to eq(:s3)
      expect(source.bucket).to eq(:uploads)
      expect(source.bucket_identifier).to eq('uploads')
      expect(source.source_identifier).to eq('uploads')
      expect(source.managed_bucket?).to be true
      expect(source.external_bucket?).to be false
      expect(source.events).to eq(['s3:ObjectCreated:*'])
      expect(source.filter).to eq('prefix' => 'incoming/', 'suffix' => '.pdf')
      expect(source.filter_prefix).to eq('incoming/')
      expect(source.filter_suffix).to eq('.pdf')
      expect(source.filter_rules).to eq(
        [
          { 'Name' => 'prefix', 'Value' => 'incoming/' },
          { 'Name' => 'suffix', 'Value' => '.pdf' }
        ]
      )
    end

    it 'supports nested s3: hash option and default events' do
      source = described_class.new(
        s3: {
          bucket: 'arn:aws:s3:::external-uploads',
          filter: { prefix: 'raw/' }
        }
      )

      expect(source.s3?).to be true
      expect(source.bucket).to eq('arn:aws:s3:::external-uploads')
      expect(source.bucket_identifier).to eq('external-uploads')
      expect(source.external_bucket?).to be true
      expect(source.managed_bucket?).to be false
      expect(source.events).to eq(['s3:ObjectCreated:*'])
      expect(source.filter).to eq('prefix' => 'raw/')
    end

    it 'raises ArgumentError if bucket is missing for S3 event source' do
      expect { described_class.new(type: :s3, bucket: nil) }
        .to raise_error(ArgumentError, /Bucket must be specified for S3 event source/)
      expect { described_class.new(type: :s3, bucket: '   ') }
        .to raise_error(ArgumentError, /Bucket must be specified for S3 event source/)
    end

    it 'raises ArgumentError if S3 events are empty or invalid' do
      expect { described_class.new(type: :s3, bucket: :uploads, events: []) }
        .to raise_error(ArgumentError, /Events cannot be empty/)
      expect { described_class.new(type: :s3, bucket: :uploads, events: ['ObjectCreated:*']) }
        .to raise_error(ArgumentError, /Invalid S3 event/)
    end

    it 'raises ArgumentError if S3 filter is invalid' do
      expect { described_class.new(type: :s3, bucket: :uploads, filter: 'invalid') }
        .to raise_error(ArgumentError, /Filter must be a Hash/)
      expect { described_class.new(type: :s3, bucket: :uploads, filter: { pattern: '*.pdf' }) }
        .to raise_error(ArgumentError, /Unsupported S3 filter keys/)
    end

    it 'creates a valid DynamoDB Stream event source with starting_position' do
      stream_arn = 'arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000'
      source = described_class.new(
        dynamodb_stream: stream_arn,
        starting_position: :trim_horizon,
        batch_size: 100,
        maximum_batching_window_in_seconds: 5,
        report_batch_item_failures: true
      )

      expect(source.dynamodb_stream?).to be true
      expect(source.sqs?).to be false
      expect(source.sns?).to be false
      expect(source.s3?).to be false
      expect(source.type).to eq(:dynamodb_stream)
      expect(source.stream).to eq(stream_arn)
      expect(source.dynamodb_stream).to eq(stream_arn)
      expect(source.stream_arn).to eq(stream_arn)
      expect(source.stream_identifier).to eq('Orders')
      expect(source.source_identifier).to eq('Orders')
      expect(source.starting_position).to eq('TRIM_HORIZON')
      expect(source.batch_size).to eq(100)
      expect(source.maximum_batching_window_in_seconds).to eq(5)
      expect(source.report_batch_item_failures?).to be true
    end

    it 'defaults starting_position to LATEST and supports nested dynamodb_stream: hash' do
      source = described_class.new(
        dynamodb_stream: {
          stream: :orders_stream,
          starting_position: :latest,
          batch_size: 50
        }
      )

      expect(source.dynamodb_stream?).to be true
      expect(source.stream).to eq(:orders_stream)
      expect(source.stream_identifier).to eq('orders_stream')
      expect(source.starting_position).to eq('LATEST')
      expect(source.batch_size).to eq(50)

      default_pos_source = described_class.new(dynamodb_stream: :users_stream)
      expect(default_pos_source.starting_position).to eq('LATEST')
    end

    it 'raises ArgumentError if stream is missing or starting_position is invalid' do
      expect { described_class.new(type: :dynamodb_stream, stream: nil) }
        .to raise_error(ArgumentError, /Stream must be specified for DynamoDB Stream event source/)
      expect { described_class.new(type: :dynamodb_stream, stream: '   ') }
        .to raise_error(ArgumentError, /Stream must be specified for DynamoDB Stream event source/)
      expect { described_class.new(dynamodb_stream: :orders_stream, starting_position: :at_timestamp) }
        .to raise_error(ArgumentError, /Invalid starting_position/)
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

    it 'serializes SNS event source attributes' do
      source = described_class.new(
        type: :sns,
        topic: 'arn:aws:sns:ap-northeast-1:123456789012:order-events',
        filter_policy: { event_type: ['created'] },
        filter_policy_scope: 'MessageAttributes'
      )

      hash = source.to_h
      expect(hash['type']).to eq('sns')
      expect(hash['topic']).to eq('arn:aws:sns:ap-northeast-1:123456789012:order-events')
      expect(hash['filter_policy']).to eq('event_type' => ['created'])
      expect(hash['filter_policy_scope']).to eq('MessageAttributes')
      expect(hash['enabled']).to be true
    end

    it 'serializes S3 event source attributes' do
      source = described_class.new(
        s3: {
          bucket: :uploads,
          events: ['s3:ObjectCreated:*'],
          filter: { prefix: 'incoming/', suffix: '.pdf' }
        }
      )

      hash = source.to_h
      expect(hash['type']).to eq('s3')
      expect(hash['bucket']).to eq(:uploads)
      expect(hash['events']).to eq(['s3:ObjectCreated:*'])
      expect(hash['filter']).to eq('prefix' => 'incoming/', 'suffix' => '.pdf')
      expect(hash['enabled']).to be true
    end

    it 'serializes DynamoDB Stream event source attributes' do
      source = described_class.new(
        dynamodb_stream: 'arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000',
        starting_position: :trim_horizon,
        batch_size: 25,
        report_batch_item_failures: true
      )

      hash = source.to_h
      expect(hash['type']).to eq('dynamodb_stream')
      expect(hash['stream']).to eq(
        'arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000'
      )
      expect(hash['starting_position']).to eq('TRIM_HORIZON')
      expect(hash['batch_size']).to eq(25)
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

    it 'accepts SNS event source hash in Function' do
      fn = Veltrunode::Model::Function.new(
        'notifier',
        handler: 'notifier.handler',
        runtime: 'ruby3.3',
        event_sources: [{ sns: :order_events, filter_policy: { type: ['alert'] } }]
      )

      expect(fn.event_sources?).to be true
      expect(fn.event_sources.first.sns?).to be true
      expect(fn.event_sources.first.topic).to eq(:order_events)
      expect(fn.event_sources.first.filter_policy).to eq('type' => ['alert'])
    end

    it 'accepts S3 event source hash in Function' do
      fn = Veltrunode::Model::Function.new(
        'converter',
        handler: 'converter.handler',
        runtime: 'ruby3.3',
        event_sources: [
          {
            s3: {
              bucket: :uploads,
              events: ['s3:ObjectCreated:*'],
              filter: { prefix: 'incoming/', suffix: '.pdf' }
            }
          }
        ]
      )

      expect(fn.event_sources?).to be true
      expect(fn.event_sources.first.s3?).to be true
      expect(fn.event_sources.first.bucket).to eq(:uploads)
      expect(fn.event_sources.first.events).to eq(['s3:ObjectCreated:*'])
      expect(fn.event_sources.first.filter).to eq('prefix' => 'incoming/', 'suffix' => '.pdf')
    end

    it 'accepts DynamoDB Stream event source hash in Function' do
      fn = Veltrunode::Model::Function.new(
        'stream_processor',
        handler: 'processor.handler',
        runtime: 'ruby3.3',
        event_sources: [
          {
            dynamodb_stream: 'arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000',
            starting_position: :latest,
            batch_size: 100
          }
        ]
      )

      expect(fn.event_sources?).to be true
      expect(fn.event_sources.first.dynamodb_stream?).to be true
      expect(fn.event_sources.first.starting_position).to eq('LATEST')
      expect(fn.event_sources.first.batch_size).to eq(100)
    end
  end
end
