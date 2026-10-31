# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'DSL event_source support' do
  it 'supports inline hash event_source sqs: "queue_name"' do
    app = Veltrunode.application 'worker-app' do
      function :worker do
        handler 'worker.handler'
        runtime 'ruby3.3'
        event_source sqs: 'arn:aws:sqs:ap-northeast-1:123456789012:tasks',
                     batch_size: 10,
                     maximum_batching_window_in_seconds: 5,
                     report_batch_item_failures: true
      end
    end

    fn = app.functions.first
    expect(fn.event_sources.size).to eq(1)

    es = fn.event_sources.first
    expect(es.sqs?).to be true
    expect(es.queue).to eq('arn:aws:sqs:ap-northeast-1:123456789012:tasks')
    expect(es.batch_size).to eq(10)
    expect(es.maximum_batching_window_in_seconds).to eq(5)
    expect(es.report_batch_item_failures?).to be true
  end

  it 'supports nested hash event_source sqs: { queue: ..., batch_size: ... }' do
    app = Veltrunode.application 'worker-app' do
      function :worker do
        handler 'worker.handler'
        runtime 'ruby3.3'
        event_source sqs: {
          queue: :orders_queue,
          batch_size: 25,
          report_batch_item_failures: true
        }
      end
    end

    es = app.functions.first.event_sources.first
    expect(es.queue).to eq(:orders_queue)
    expect(es.batch_size).to eq(25)
    expect(es.report_batch_item_failures?).to be true
  end

  it 'supports block-based DSL' do
    app = Veltrunode.application 'worker-app' do
      function :worker do
        handler 'worker.handler'
        runtime 'ruby3.3'
        event_source :sqs do
          queue 'my-tasks-queue'
          batch_size 100
          batch_window 20
          report_batch_item_failures true
        end
      end
    end

    es = app.functions.first.event_sources.first
    expect(es.queue).to eq('my-tasks-queue')
    expect(es.batch_size).to eq(100)
    expect(es.maximum_batching_window_in_seconds).to eq(20)
    expect(es.report_batch_item_failures?).to be true
  end

  it 'supports passing event_source as function keyword argument' do
    app = Veltrunode.application 'worker-app' do
      function :worker, event_source: { sqs: 'job-queue', batch_size: 5 } do
        handler 'worker.handler'
        runtime 'ruby3.3'
      end
    end

    es = app.functions.first.event_sources.first
    expect(es.queue).to eq('job-queue')
    expect(es.batch_size).to eq(5)
  end

  it 'supports multiple event sources on single function' do
    app = Veltrunode.application 'worker-app' do
      function :multi_worker do
        handler 'worker.handler'
        runtime 'ruby3.3'
        event_source sqs: 'high-priority-queue', batch_size: 1
        event_source sqs: 'low-priority-queue', batch_size: 10
      end
    end

    fn = app.functions.first
    expect(fn.event_sources.size).to eq(2)
    expect(fn.event_sources[0].queue).to eq('high-priority-queue')
    expect(fn.event_sources[1].queue).to eq('low-priority-queue')
  end

  it 'supports application-level defaults with opt-out' do
    app = Veltrunode.application 'default-app' do
      defaults do
        event_source sqs: 'default-queue', batch_size: 10
      end

      function :standard do
        handler 'std.handler'
        runtime 'ruby3.3'
      end

      function :standalone do
        handler 'none.handler'
        runtime 'ruby3.3'
        event_source false
      end
    end

    std_fn = app.functions.find { |f| f.logical_name == 'standard' }
    none_fn = app.functions.find { |f| f.logical_name == 'standalone' }

    expect(std_fn.event_sources.size).to eq(1)
    expect(std_fn.event_sources.first.queue).to eq('default-queue')

    expect(none_fn.event_sources).to be_empty
  end

  describe 'SNS event source DSL' do
    it 'supports inline hash event_source sns: "topic_arn" with filter_policy' do
      app = Veltrunode.application 'sns-app' do
        function :notifier do
          handler 'notifier.handler'
          runtime 'ruby3.3'
          event_source sns: 'arn:aws:sns:ap-northeast-1:123456789012:order-events',
                       filter_policy: { event_type: %w[order_created order_cancelled] }
        end
      end

      fn = app.functions.first
      expect(fn.event_sources.size).to eq(1)

      es = fn.event_sources.first
      expect(es.sns?).to be true
      expect(es.topic).to eq('arn:aws:sns:ap-northeast-1:123456789012:order-events')
      expect(es.topic_identifier).to eq('order-events')
      expect(es.filter_policy).to eq('event_type' => %w[order_created order_cancelled])
    end

    it 'supports ref(:topic) and symbolic topic in event_source sns:' do
      app = Veltrunode.application 'sns-app' do
        function :notifier do
          handler 'notifier.handler'
          runtime 'ruby3.3'
          event_source sns: ref(:alert_topic),
                       filter_policy: { severity: ['critical'] }
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.sns?).to be true
      expect(es.topic).to be_a(Veltrunode::DSL::Reference)
      expect(es.topic.name).to eq(:alert_topic)
      expect(es.topic_identifier).to eq('alert_topic')
      expect(es.filter_policy).to eq('severity' => ['critical'])
    end

    it 'supports nested hash event_source sns: { topic: ..., filter_policy: ... }' do
      app = Veltrunode.application 'sns-app' do
        function :notifier do
          handler 'notifier.handler'
          runtime 'ruby3.3'
          event_source sns: {
            topic: :order_events,
            filter_policy: { store: ['tokyo'] },
            filter_policy_scope: 'MessageBody'
          }
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.sns?).to be true
      expect(es.topic).to eq(:order_events)
      expect(es.filter_policy).to eq('store' => ['tokyo'])
      expect(es.filter_policy_scope).to eq('MessageBody')
    end

    it 'supports block-based event_source :sns DSL' do
      app = Veltrunode.application 'sns-app' do
        function :notifier do
          handler 'notifier.handler'
          runtime 'ruby3.3'
          event_source :sns do
            topic 'arn:aws:sns:ap-northeast-1:123456789012:user-events'
            filter_policy event_type: ['signup']
            filter_policy_scope :message_attributes
          end
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.sns?).to be true
      expect(es.topic).to eq('arn:aws:sns:ap-northeast-1:123456789012:user-events')
      expect(es.filter_policy).to eq('event_type' => ['signup'])
      expect(es.filter_policy_scope).to eq('MessageAttributes')
    end

    it 'supports passing SNS event_source as function keyword argument' do
      app = Veltrunode.application 'sns-app' do
        function :notifier, event_source: { sns: :order_topic, filter_policy: { status: ['paid'] } } do
          handler 'notifier.handler'
          runtime 'ruby3.3'
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.sns?).to be true
      expect(es.topic).to eq(:order_topic)
      expect(es.filter_policy).to eq('status' => ['paid'])
    end

    it 'supports SNS event_source in application defaults with opt-out' do
      app = Veltrunode.application 'sns-default-app' do
        defaults do
          event_source sns: :system_events, filter_policy: { env: ['prod'] }
        end

        function :subscriber do
          handler 'sub.handler'
          runtime 'ruby3.3'
        end

        function :standalone do
          handler 'none.handler'
          runtime 'ruby3.3'
          event_source false
        end
      end

      sub_fn = app.functions.find { |f| f.logical_name == 'subscriber' }
      none_fn = app.functions.find { |f| f.logical_name == 'standalone' }

      expect(sub_fn.event_sources.size).to eq(1)
      expect(sub_fn.event_sources.first.sns?).to be true
      expect(sub_fn.event_sources.first.topic).to eq(:system_events)
      expect(none_fn.event_sources).to be_empty
    end
  end

  describe 'S3 event source DSL' do
    it 'supports nested hash event_source s3: { bucket: ..., events: ..., filter: ... }' do
      app = Veltrunode.application 's3-app' do
        function :convert do
          handler 'convert.handler'
          runtime 'ruby3.3'
          event_source s3: {
            bucket: :uploads,
            events: ['s3:ObjectCreated:*'],
            filter: { prefix: 'incoming/', suffix: '.jpg' }
          }
        end
      end

      fn = app.functions.first
      expect(fn.event_sources.size).to eq(1)

      es = fn.event_sources.first
      expect(es.s3?).to be true
      expect(es.bucket).to eq(:uploads)
      expect(es.bucket_identifier).to eq('uploads')
      expect(es.events).to eq(['s3:ObjectCreated:*'])
      expect(es.filter).to eq('prefix' => 'incoming/', 'suffix' => '.jpg')
      expect(es.filter_rules).to eq([
                                      { 'Name' => 'prefix', 'Value' => 'incoming/' },
                                      { 'Name' => 'suffix', 'Value' => '.jpg' }
                                    ])
    end

    it 'supports inline hash event_source s3: :uploads with events and prefix/suffix' do
      app = Veltrunode.application 's3-app' do
        function :convert do
          handler 'convert.handler'
          runtime 'ruby3.3'
          event_source s3: :uploads,
                       events: ['s3:ObjectCreated:Put', 's3:ObjectCreated:Post'],
                       prefix: 'raw/',
                       suffix: '.png'
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.s3?).to be true
      expect(es.bucket).to eq(:uploads)
      expect(es.events).to eq(['s3:ObjectCreated:Put', 's3:ObjectCreated:Post'])
      expect(es.filter_prefix).to eq('raw/')
      expect(es.filter_suffix).to eq('.png')
    end

    it 'supports ref(:bucket) in event_source s3:' do
      app = Veltrunode.application 's3-app' do
        function :convert do
          handler 'convert.handler'
          runtime 'ruby3.3'
          event_source s3: {
            bucket: ref(:input_bucket),
            events: ['s3:ObjectCreated:*'],
            filter: { prefix: 'uploads/' }
          }
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.s3?).to be true
      expect(es.bucket).to be_a(Veltrunode::DSL::Reference)
      expect(es.bucket.name).to eq(:input_bucket)
      expect(es.bucket_identifier).to eq('input_bucket')
      expect(es.external_bucket?).to be true
    end

    it 'supports block-based event_source :s3 DSL' do
      app = Veltrunode.application 's3-app' do
        function :convert do
          handler 'convert.handler'
          runtime 'ruby3.3'
          event_source :s3 do
            bucket :media_bucket
            events 's3:ObjectCreated:*', 's3:ObjectRemoved:*'
            filter prefix: 'videos/', suffix: '.mp4'
          end
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.s3?).to be true
      expect(es.bucket).to eq(:media_bucket)
      expect(es.events).to eq(['s3:ObjectCreated:*', 's3:ObjectRemoved:*'])
      expect(es.filter).to eq('prefix' => 'videos/', 'suffix' => '.mp4')
    end

    it 'supports passing S3 event_source as function keyword argument' do
      app = Veltrunode.application 's3-app' do
        function :convert, event_source: {
          s3: {
            bucket: :uploads,
            events: ['s3:ObjectCreated:*'],
            filter: { prefix: 'incoming/', suffix: '.csv' }
          }
        } do
          handler 'convert.handler'
          runtime 'ruby3.3'
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.s3?).to be true
      expect(es.bucket).to eq(:uploads)
      expect(es.events).to eq(['s3:ObjectCreated:*'])
      expect(es.filter).to eq('prefix' => 'incoming/', 'suffix' => '.csv')
    end

    it 'supports S3 event_source in application defaults with opt-out' do
      app = Veltrunode.application 's3-default-app' do
        defaults do
          event_source s3: { bucket: :shared_uploads, filter: { prefix: 'jobs/' } }
        end

        function :processor do
          handler 'proc.handler'
          runtime 'ruby3.3'
        end

        function :standalone do
          handler 'none.handler'
          runtime 'ruby3.3'
          event_source false
        end
      end

      proc_fn = app.functions.find { |f| f.logical_name == 'processor' }
      none_fn = app.functions.find { |f| f.logical_name == 'standalone' }

      expect(proc_fn.event_sources.size).to eq(1)
      expect(proc_fn.event_sources.first.s3?).to be true
      expect(proc_fn.event_sources.first.bucket).to eq(:shared_uploads)
      expect(proc_fn.event_sources.first.filter).to eq('prefix' => 'jobs/')
      expect(none_fn.event_sources).to be_empty
    end
  end

  describe 'DynamoDB Stream event source DSL' do
    let(:stream_arn) do
      'arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000'
    end

    it 'supports inline hash event_source dynamodb_stream: ... with starting_position: :latest' do
      arn = stream_arn
      app = Veltrunode.application 'ddb-stream-app' do
        function :order_projector do
          handler 'projector.handler'
          runtime 'ruby3.3'
          event_source dynamodb_stream: arn,
                       starting_position: :latest,
                       batch_size: 100,
                       maximum_batching_window_in_seconds: 5,
                       report_batch_item_failures: true
        end
      end

      fn = app.functions.first
      expect(fn.event_sources.size).to eq(1)

      es = fn.event_sources.first
      expect(es.dynamodb_stream?).to be true
      expect(es.stream).to eq(stream_arn)
      expect(es.stream_identifier).to eq('Orders')
      expect(es.starting_position).to eq('LATEST')
      expect(es.batch_size).to eq(100)
      expect(es.maximum_batching_window_in_seconds).to eq(5)
      expect(es.report_batch_item_failures?).to be true
    end

    it 'supports nested hash event_source dynamodb_stream: { stream: ..., starting_position: :trim_horizon }' do
      app = Veltrunode.application 'ddb-stream-app' do
        function :order_projector do
          handler 'projector.handler'
          runtime 'ruby3.3'
          event_source dynamodb_stream: {
            stream: ref(:orders_stream_arn),
            starting_position: :trim_horizon,
            batch_size: 50
          }
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.dynamodb_stream?).to be true
      expect(es.stream).to be_a(Veltrunode::DSL::Reference)
      expect(es.stream.name).to eq(:orders_stream_arn)
      expect(es.stream_identifier).to eq('orders_stream_arn')
      expect(es.starting_position).to eq('TRIM_HORIZON')
      expect(es.batch_size).to eq(50)
    end

    it 'supports block-based event_source :dynamodb_stream DSL' do
      arn = stream_arn
      app = Veltrunode.application 'ddb-stream-app' do
        function :order_projector do
          handler 'projector.handler'
          runtime 'ruby3.3'
          event_source :dynamodb_stream do
            stream arn
            starting_position :trim_horizon
            batch_size 200
            batch_window 10
            report_batch_item_failures true
          end
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.dynamodb_stream?).to be true
      expect(es.stream).to eq(stream_arn)
      expect(es.starting_position).to eq('TRIM_HORIZON')
      expect(es.batch_size).to eq(200)
      expect(es.maximum_batching_window_in_seconds).to eq(10)
      expect(es.report_batch_item_failures?).to be true
    end

    it 'supports passing DynamoDB Stream event_source as function keyword argument' do
      arn = stream_arn
      app = Veltrunode.application 'ddb-stream-app' do
        function :order_projector, event_source: {
          dynamodb_stream: arn,
          starting_position: :latest,
          batch_size: 25
        } do
          handler 'projector.handler'
          runtime 'ruby3.3'
        end
      end

      es = app.functions.first.event_sources.first
      expect(es.dynamodb_stream?).to be true
      expect(es.stream).to eq(stream_arn)
      expect(es.starting_position).to eq('LATEST')
      expect(es.batch_size).to eq(25)
    end

    it 'supports DynamoDB Stream event_source in application defaults with opt-out' do
      arn = stream_arn
      app = Veltrunode.application 'ddb-default-app' do
        defaults do
          event_source dynamodb_stream: arn, starting_position: :trim_horizon
        end

        function :projector do
          handler 'proj.handler'
          runtime 'ruby3.3'
        end

        function :standalone do
          handler 'none.handler'
          runtime 'ruby3.3'
          event_source false
        end
      end

      proj_fn = app.functions.find { |f| f.logical_name == 'projector' }
      none_fn = app.functions.find { |f| f.logical_name == 'standalone' }

      expect(proj_fn.event_sources.size).to eq(1)
      expect(proj_fn.event_sources.first.dynamodb_stream?).to be true
      expect(proj_fn.event_sources.first.starting_position).to eq('TRIM_HORIZON')
      expect(none_fn.event_sources).to be_empty
    end
  end
end
