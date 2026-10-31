# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/event_source'

module Veltrunode
  module DSL
    class EventSourceBuilder < BaseBuilder
      def initialize(type = :sqs, queue: nil, topic: nil, topic_arn: nil, bucket: nil,
                     events: nil, event: nil, filter: nil, prefix: nil, suffix: nil,
                     stream: nil, stream_arn: nil, arn: nil, starting_position: nil,
                     batch_size: nil, maximum_batching_window_in_seconds: nil, report_batch_item_failures: false,
                     filter_policy: nil, filter_policy_scope: nil, enabled: true, **)
        super()
        @type = type.to_sym
        @queue = queue
        @topic = topic || topic_arn
        @bucket = bucket
        @events = events || event
        @filter = filter
        @prefix = prefix
        @suffix = suffix
        @stream = stream || stream_arn || arn
        @starting_position = starting_position
        @batch_size = batch_size
        @maximum_batching_window_in_seconds = maximum_batching_window_in_seconds
        @report_batch_item_failures = report_batch_item_failures
        @filter_policy = filter_policy
        @filter_policy_scope = filter_policy_scope
        @enabled = enabled
      end

      def queue(q)
        @queue = q
      end

      def topic(t)
        @topic = t
      end
      alias topic_arn topic

      def bucket(b)
        @bucket = b
      end

      def events(*evts)
        @events = evts.flatten
      end
      alias event events

      def filter(f = nil, **kwargs)
        @filter = if f.is_a?(Hash)
                    f.merge(kwargs)
                  elsif kwargs.empty?
                    f
                  else
                    kwargs
                  end
      end

      def prefix(p)
        @prefix = p
      end

      def suffix(s)
        @suffix = s
      end

      def stream(s)
        @stream = s
      end
      alias stream_arn stream
      alias dynamodb_stream stream

      def starting_position(pos)
        @starting_position = pos
      end

      def batch_size(size)
        @batch_size = size
      end

      def maximum_batching_window_in_seconds(window)
        @maximum_batching_window_in_seconds = window
      end
      alias batch_window maximum_batching_window_in_seconds
      alias max_batching_window maximum_batching_window_in_seconds

      def report_batch_item_failures(enabled = true) # rubocop:disable Style/OptionalBooleanParameter
        @report_batch_item_failures = enabled
      end

      def filter_policy(policy = nil, **kwargs)
        @filter_policy = if policy.is_a?(Hash)
                           policy.merge(kwargs)
                         elsif kwargs.empty?
                           policy
                         else
                           kwargs
                         end
      end

      def filter_policy_scope(scope)
        @filter_policy_scope = scope
      end

      def enabled(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @enabled = flag
      end

      def build
        Model::EventSource.new(
          type: @type,
          queue: @queue,
          topic: @topic,
          bucket: @bucket,
          events: @events,
          filter: @filter,
          prefix: @prefix,
          suffix: @suffix,
          stream: @stream,
          starting_position: @starting_position,
          batch_size: @batch_size,
          maximum_batching_window_in_seconds: @maximum_batching_window_in_seconds,
          report_batch_item_failures: @report_batch_item_failures,
          filter_policy: @filter_policy,
          filter_policy_scope: @filter_policy_scope,
          enabled: @enabled
        )
      end
    end
  end
end
