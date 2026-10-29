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
end
