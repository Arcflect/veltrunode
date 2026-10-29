# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/event_source'

module Veltrunode
  module DSL
    class EventSourceBuilder < BaseBuilder
      def initialize(type = :sqs, queue: nil, batch_size: nil, maximum_batching_window_in_seconds: nil,
                     report_batch_item_failures: false, enabled: true, **)
        super()
        @type = type.to_sym
        @queue = queue
        @batch_size = batch_size
        @maximum_batching_window_in_seconds = maximum_batching_window_in_seconds
        @report_batch_item_failures = report_batch_item_failures
        @enabled = enabled
      end

      def queue(q)
        @queue = q
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

      def enabled(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @enabled = flag
      end

      def build
        Model::EventSource.new(
          type: @type,
          queue: @queue,
          batch_size: @batch_size,
          maximum_batching_window_in_seconds: @maximum_batching_window_in_seconds,
          report_batch_item_failures: @report_batch_item_failures,
          enabled: @enabled
        )
      end
    end
  end
end
