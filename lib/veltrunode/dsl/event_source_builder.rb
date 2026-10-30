# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/event_source'

module Veltrunode
  module DSL
    class EventSourceBuilder < BaseBuilder
      def initialize(type = :sqs, queue: nil, topic: nil, topic_arn: nil, batch_size: nil,
                     maximum_batching_window_in_seconds: nil, report_batch_item_failures: false,
                     filter_policy: nil, filter_policy_scope: nil, enabled: true, **)
        super()
        @type = type.to_sym
        @queue = queue
        @topic = topic || topic_arn
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
