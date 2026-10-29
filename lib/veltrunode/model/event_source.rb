# frozen_string_literal: true

module Veltrunode
  module Model
    # Lambda 関数のイベントソース（EventSourceMapping）を表す値オブジェクト
    class EventSource
      SUPPORTED_TYPES = %i[sqs].freeze

      attr_reader :type, :queue, :batch_size, :maximum_batching_window_in_seconds, :report_batch_item_failures

      # @param type [Symbol, String] イベントソース種別 (:sqs)
      # @param queue [String, Symbol] SQS キュー名または ARN
      # @param batch_size [Integer, nil] バッチサイズ (1〜10,000)
      # @param maximum_batching_window_in_seconds [Integer, nil] バッチウィンドウ秒数 (0〜300)
      # @param report_batch_item_failures [Boolean] 部分失敗報告 (ReportBatchItemFailures) を有効化するか
      # @param enabled [Boolean] マッピングを有効化するか
      def initialize(
        type: :sqs,
        queue: nil,
        batch_size: nil,
        maximum_batching_window_in_seconds: nil,
        report_batch_item_failures: false,
        enabled: true
      )
        @type = normalize_type(type)
        @queue = normalize_queue(queue)
        @batch_size = normalize_batch_size(batch_size)
        @maximum_batching_window_in_seconds = normalize_batching_window(maximum_batching_window_in_seconds)
        @report_batch_item_failures = report_batch_item_failures ? true : false
        @enabled = enabled.nil? || enabled
        freeze
      end

      def sqs?
        @type == :sqs
      end

      def report_batch_item_failures?
        @report_batch_item_failures
      end

      def enabled?
        @enabled
      end

      def queue_identifier
        return @queue.to_s if @queue.is_a?(Symbol)

        q_str = @queue.to_s
        if q_str.start_with?('arn:')
          q_str.split(':').last
        else
          q_str
        end
      end

      def to_h
        {
          'type' => @type.to_s,
          'queue' => @queue,
          'batch_size' => @batch_size,
          'maximum_batching_window_in_seconds' => @maximum_batching_window_in_seconds,
          'report_batch_item_failures' => @report_batch_item_failures,
          'enabled' => @enabled
        }.compact
      end

      private

      def normalize_type(type_val)
        sym = type_val.to_s.downcase.to_sym
        unless SUPPORTED_TYPES.include?(sym)
          raise ArgumentError,
                "Unsupported event source type '#{type_val}'. Supported types: #{SUPPORTED_TYPES.join(', ')}"
        end

        sym
      end

      def normalize_queue(queue_val)
        if queue_val.nil? || queue_val.to_s.strip.empty?
          raise ArgumentError, 'Queue must be specified for SQS event source.'
        end

        queue_val.is_a?(Symbol) ? queue_val : queue_val.to_s.strip.freeze
      end

      def normalize_batch_size(size)
        return nil if size.nil?

        int_val = size.to_i
        raise ArgumentError, "Batch size must be between 1 and 10000, got #{size}." unless (1..10_000).cover?(int_val)

        int_val
      end

      def normalize_batching_window(window)
        return nil if window.nil?

        int_val = window.to_i
        unless (0..300).cover?(int_val)
          raise ArgumentError, "Maximum batching window must be between 0 and 300 seconds, got #{window}."
        end

        int_val
      end
    end
  end
end
