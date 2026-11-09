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
      expect { described_class.new(type: :unknown_source, queue: 'stream') }
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

    it 'creates a Kinesis Data Stream event source with parallelization_factor and bisect_batch_on_function_error' do
      stream_arn = 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/clickstream-events'
      source = described_class.new(
        kinesis_stream: stream_arn,
        starting_position: :latest,
        batch_size: 500,
        maximum_batching_window_in_seconds: 10,
        parallelization_factor: 5,
        bisect_batch_on_function_error: true,
        report_batch_item_failures: true
      )

      expect(source.kinesis_stream?).to be true
      expect(source.kinesis?).to be true
      expect(source.dynamodb_stream?).to be false
      expect(source.type).to eq(:kinesis_stream)
      expect(source.stream).to eq(stream_arn)
      expect(source.kinesis_stream).to eq(stream_arn)
      expect(source.stream_identifier).to eq('clickstream-events')
      expect(source.source_identifier).to eq('clickstream-events')
      expect(source.starting_position).to eq('LATEST')
      expect(source.batch_size).to eq(500)
      expect(source.maximum_batching_window_in_seconds).to eq(10)
      expect(source.parallelization_factor).to eq(5)
      expect(source.bisect_batch_on_function_error).to be true
      expect(source.bisect_batch_on_function_error?).to be true
      expect(source.report_batch_item_failures?).to be true
    end

    it 'raises ArgumentError if kinesis_stream is missing or parallelization_factor is out of range' do
      expect { described_class.new(type: :kinesis_stream, stream: nil) }
        .to raise_error(ArgumentError, /Stream must be specified for Kinesis Stream event source/)
      expect { described_class.new(kinesis_stream: :clickstream, parallelization_factor: 0) }
        .to raise_error(ArgumentError, /Parallelization factor must be between 1 and 10/)
      expect { described_class.new(kinesis_stream: :clickstream, parallelization_factor: 11) }
        .to raise_error(ArgumentError, /Parallelization factor must be between 1 and 10/)
    end

    it 'creates an EventBridge rule event source with bus, pattern, and default enabled state' do
      source = described_class.new(
        rule: {
          bus: 'custom-domain-bus',
          pattern: {
            source: ['myapp.orders'],
            'detail-type': %w[OrderCreated OrderCompleted]
          }
        }
      )

      expect(source.type).to eq(:rule)
      expect(source.rule?).to be true
      expect(source.bus).to eq('custom-domain-bus')
      expect(source.event_bus).to eq('custom-domain-bus')
      expect(source.pattern).to eq(
        'source' => ['myapp.orders'],
        'detail-type' => %w[OrderCreated OrderCompleted]
      )
      expect(source.event_pattern).to eq(source.pattern)
      expect(source.state).to eq(:enabled)
      expect(source.cfn_state).to eq('ENABLED')
      expect(source.enabled?).to be true
      expect(source.disabled?).to be false
      expect(source.source_identifier).to eq('custom-domain-bus')
    end

    it 'supports rule disabling with state: :disabled' do
      source = described_class.new(
        rule: {
          bus: :domain_events,
          pattern: { source: ['myapp.billing'], 'detail-type': ['InvoiceIssued'] },
          state: :disabled
        }
      )

      expect(source.rule?).to be true
      expect(source.state).to eq(:disabled)
      expect(source.cfn_state).to eq('DISABLED')
      expect(source.enabled?).to be false
      expect(source.disabled?).to be true
    end

    it 'accepts type: :rule directly without bus (defaults to default bus)' do
      source = described_class.new(
        type: :rule,
        name: :order_created,
        pattern: {
          source: ['myapp.orders'],
          detail: { status: ['PAID'] }
        },
        description: 'Trigger on paid orders'
      )

      expect(source.rule?).to be true
      expect(source.name).to eq('order_created')
      expect(source.bus).to be_nil
      expect(source.pattern).to eq(
        'source' => ['myapp.orders'],
        'detail' => { 'status' => ['PAID'] }
      )
      expect(source.description).to eq('Trigger on paid orders')
      expect(source.source_identifier).to eq('order_created')
    end

    it 'raises ArgumentError when rule pattern is missing or invalid' do
      expect do
        described_class.new(type: :rule, bus: 'custom-bus')
      end.to raise_error(ArgumentError, /Event pattern must be specified for EventBridge rule/)

      expect do
        described_class.new(rule: { bus: 'custom-bus', pattern: {} })
      end.to raise_error(ArgumentError, /Event pattern must be specified for EventBridge rule/)

      expect do
        described_class.new(rule: { bus: 'custom-bus', pattern: 'invalid' })
      end.to raise_error(ArgumentError, /Event pattern must be a Hash/)
    end

    it 'raises ArgumentError when rule state or bus is invalid' do
      expect do
        described_class.new(
          rule: {
            bus: '   ',
            pattern: { source: ['myapp.orders'] }
          }
        )
      end.to raise_error(ArgumentError, /Event bus cannot be empty for EventBridge rule/)

      expect do
        described_class.new(
          rule: {
            pattern: { source: ['myapp.orders'] },
            state: :paused
          }
        )
      end.to raise_error(ArgumentError, /Invalid rule state 'paused'/)
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

    it 'serializes Kinesis Stream event source attributes' do
      source = described_class.new(
        kinesis_stream: 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/clickstream',
        starting_position: :trim_horizon,
        batch_size: 200,
        parallelization_factor: 4,
        bisect_batch_on_function_error: true
      )

      hash = source.to_h
      expect(hash['type']).to eq('kinesis_stream')
      expect(hash['stream']).to eq('arn:aws:kinesis:ap-northeast-1:123456789012:stream/clickstream')
      expect(hash['starting_position']).to eq('TRIM_HORIZON')
      expect(hash['batch_size']).to eq(200)
      expect(hash['parallelization_factor']).to eq(4)
      expect(hash['bisect_batch_on_function_error']).to be true
      expect(hash['enabled']).to be true
    end

    it 'serializes EventBridge rule event source attributes' do
      source = described_class.new(
        rule: {
          name: :order_created,
          bus: 'custom-bus',
          pattern: { source: ['myapp.orders'], 'detail-type': ['OrderCreated'] },
          state: :disabled,
          description: 'Disabled order rule'
        }
      )

      hash = source.to_h
      expect(hash['type']).to eq('rule')
      expect(hash['name']).to eq('order_created')
      expect(hash['bus']).to eq('custom-bus')
      expect(hash['pattern']).to eq('source' => ['myapp.orders'], 'detail-type' => ['OrderCreated'])
      expect(hash['state']).to eq('disabled')
      expect(hash['description']).to eq('Disabled order rule')
      expect(hash['enabled']).to be false
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

    it 'accepts rule hash in Function and exposes #rule and #rules helpers' do
      fn = Veltrunode::Model::Function.new(
        'order_handler',
        handler: 'orders.handler',
        runtime: 'ruby3.3',
        rule: {
          bus: 'custom-bus',
          pattern: { source: ['myapp.orders'], 'detail-type': ['OrderCreated'] },
          state: :disabled
        }
      )

      expect(fn.event_sources?).to be true
      expect(fn.rules?).to be true
      expect(fn.rules.size).to eq(1)
      expect(fn.rule.rule?).to be true
      expect(fn.rule.bus).to eq('custom-bus')
      expect(fn.rule.pattern).to eq('source' => ['myapp.orders'], 'detail-type' => ['OrderCreated'])
      expect(fn.rule.state).to eq(:disabled)
      expect(fn.rule.disabled?).to be true
    end

    it 'creates Amazon MSK and Amazon MQ event sources with topics, secret, starting_position, and VPC config' do
      cluster_arn = 'arn:aws:kafka:ap-northeast-1:123456789012:cluster/orders-cluster/12345678-1234-1234-1234-12345678'
      secret_arn = 'arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:AmazonMSK_orders-AbCdEf'
      msk_source = described_class.new(
        msk: {
          cluster: cluster_arn,
          topics: %w[orders.created orders.updated],
          starting_position: :trim_horizon,
          secret: secret_arn,
          auth_type: :sasl_scram_512_auth,
          consumer_group_id: 'orders-consumer-group',
          batch_size: 200,
          security_group_ids: ['sg-0123456789abcdef0'],
          subnet_ids: %w[subnet-11111111 subnet-22222222]
        }
      )

      expect(msk_source.msk?).to be true
      expect(msk_source.kafka?).to be true
      expect(msk_source.broker?).to be true
      expect(msk_source.cluster).to eq(cluster_arn)
      expect(msk_source.cluster_identifier).to eq('orders-cluster')
      expect(msk_source.source_identifier).to eq('orders-cluster')
      expect(msk_source.topics).to eq(%w[orders.created orders.updated])
      expect(msk_source.topic).to eq('orders.created')
      expect(msk_source.starting_position).to eq('TRIM_HORIZON')
      expect(msk_source.secret).to eq(secret_arn)
      expect(msk_source.auth_type).to eq('SASL_SCRAM_512_AUTH')
      expect(msk_source.consumer_group_id).to eq('orders-consumer-group')
      expect(msk_source.batch_size).to eq(200)
      expect(msk_source.security_group_ids).to eq(['sg-0123456789abcdef0'])
      expect(msk_source.subnet_ids).to eq(%w[subnet-11111111 subnet-22222222])

      broker_arn = 'arn:aws:mq:ap-northeast-1:123456789012:broker:orders-mq:b-12345678-1234-1234-1234-123456789012'
      mq_secret = 'arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:mq/broker-credentials-XyZ123'
      mq_source = described_class.new(
        mq: {
          broker: broker_arn,
          queues: ['orders.fulfillment'],
          secret: mq_secret,
          virtual_host: '/production',
          batch_size: 50
        }
      )

      expect(mq_source.mq?).to be true
      expect(mq_source.amazon_mq?).to be true
      expect(mq_source.broker?).to be true
      expect(mq_source.broker).to eq(broker_arn)
      expect(mq_source.broker_identifier).to eq('orders-mq')
      expect(mq_source.source_identifier).to eq('orders-mq')
      expect(mq_source.queues).to eq(['orders.fulfillment'])
      expect(mq_source.topics).to eq(['orders.fulfillment'])
      expect(mq_source.secret).to eq(mq_secret)
      expect(mq_source.auth_type).to eq('BASIC_AUTH')
      expect(mq_source.virtual_host).to eq('/production')
      expect(mq_source.batch_size).to eq(50)
    end

    it 'validates broker secret and VPC security_group_ids/subnet_ids in Function#validate_invariants' do
      broker_arn = 'arn:aws:mq:ap-northeast-1:123456789012:broker:orders-mq:b-12345678'
      fn_missing_secret = Veltrunode::Model::Function.new(
        'mq_worker',
        handler: 'worker.handler',
        runtime: 'ruby3.3',
        event_sources: [{ mq: { broker: broker_arn, queues: ['orders.queue'] } }]
      )
      diags = fn_missing_secret.validate_invariants
      expect(diags.map(&:code)).to include('VLT-IAM-003')

      cluster_arn = 'arn:aws:kafka:ap-northeast-1:123456789012:cluster/orders-cluster/uuid-1'
      fn_incomplete_vpc = Veltrunode::Model::Function.new(
        'msk_worker',
        handler: 'worker.handler',
        runtime: 'ruby3.3',
        vpc_reference: { subnet_ids: ['subnet-11111111'] },
        event_sources: [{ msk: { cluster: cluster_arn, topics: ['orders.events'] } }]
      )
      vpc_diags = fn_incomplete_vpc.validate_invariants
      expect(vpc_diags.map(&:code)).to include('VLT-DSL-VPC-001')
    end
  end
end
