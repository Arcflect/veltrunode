# frozen_string_literal: true

module Veltrunode
  module Model
    # Lambda 関数のイベントソース（SQS EventSourceMapping / SNS Subscription）を表す値オブジェクト
    class EventSource
      SUPPORTED_TYPES = %i[sqs sns].freeze
      VALID_FILTER_POLICY_SCOPES = %w[MessageAttributes MessageBody].freeze

      attr_reader :type, :queue, :batch_size, :maximum_batching_window_in_seconds, :report_batch_item_failures,
                  :topic, :filter_policy, :filter_policy_scope

      # @param type [Symbol, String, nil] イベントソース種別 (:sqs, :sns)
      # @param queue [String, Symbol, nil] SQS キュー名または ARN
      # @param sqs [String, Symbol, Hash, nil] SQS キュー指定またはオプションハッシュ
      # @param topic [String, Symbol, Hash, DSL::Reference, nil] SNS トピック ARN または参照
      # @param topic_arn [String, Symbol, Hash, DSL::Reference, nil] SNS トピック ARN または参照 (topic のエイリアス)
      # @param sns [String, Symbol, Hash, DSL::Reference, nil] SNS トピック指定またはオプションハッシュ
      # @param batch_size [Integer, nil] バッチサイズ (1〜10,000)
      # @param maximum_batching_window_in_seconds [Integer, nil] バッチウィンドウ秒数 (0〜300)
      # @param report_batch_item_failures [Boolean] 部分失敗報告 (ReportBatchItemFailures) を有効化するか
      # @param filter_policy [Hash, nil] SNS サブスクリプションのフィルタポリシー (FilterPolicy)
      # @param filter_policy_scope [String, Symbol, nil] フィルタポリシーの適用範囲 (MessageAttributes / MessageBody)
      # @param enabled [Boolean] イベントソースを有効化するか
      def initialize(
        type: nil,
        queue: nil,
        sqs: nil,
        topic: nil,
        topic_arn: nil,
        sns: nil,
        batch_size: nil,
        maximum_batching_window_in_seconds: nil,
        report_batch_item_failures: false,
        filter_policy: nil,
        filter_policy_scope: nil,
        enabled: true
      )
        resolved = resolve_options(
          type: type, queue: queue, sqs: sqs, topic: topic, topic_arn: topic_arn, sns: sns,
          batch_size: batch_size, maximum_batching_window_in_seconds: maximum_batching_window_in_seconds,
          report_batch_item_failures: report_batch_item_failures, filter_policy: filter_policy,
          filter_policy_scope: filter_policy_scope, enabled: enabled
        )

        @type = normalize_type(resolved[:type])
        if sqs?
          init_sqs_attributes(resolved)
        else
          init_sns_attributes(resolved)
        end
        @enabled = resolved[:enabled].nil? || resolved[:enabled]
        freeze
      end

      def sqs?
        @type == :sqs
      end

      def sns?
        @type == :sns
      end

      def report_batch_item_failures?
        @report_batch_item_failures
      end

      def enabled?
        @enabled
      end

      def queue_identifier
        return nil if @queue.nil?
        return @queue.to_s if @queue.is_a?(Symbol)
        return @queue.name.to_s if @queue.respond_to?(:name)

        q_str = @queue.to_s
        if q_str.start_with?('arn:')
          q_str.split(':').last
        else
          q_str
        end
      end

      def topic_identifier
        return nil if @topic.nil?
        return @topic.to_s if @topic.is_a?(Symbol)
        return @topic.name.to_s if @topic.respond_to?(:name)

        if @topic.is_a?(Hash)
          ref_val = @topic['Ref'] || @topic[:Ref] || @topic[:ref] || @topic['ref']
          return ref_val.to_s if ref_val

          get_att = @topic['Fn::GetAtt'] || @topic[:'Fn::GetAtt']
          return Array(get_att).first.to_s if get_att

          return nil
        end

        t_str = @topic.to_s
        if t_str.start_with?('arn:')
          t_str.split(':').last
        else
          t_str
        end
      end

      def source_identifier
        sqs? ? queue_identifier : topic_identifier
      end

      def to_h
        if sns?
          topic_val = @topic.respond_to?(:name) ? @topic.name.to_s : @topic
          {
            'type' => @type.to_s,
            'topic' => topic_val,
            'filter_policy' => @filter_policy,
            'filter_policy_scope' => @filter_policy_scope,
            'enabled' => @enabled
          }.compact
        else
          {
            'type' => @type.to_s,
            'queue' => @queue,
            'batch_size' => @batch_size,
            'maximum_batching_window_in_seconds' => @maximum_batching_window_in_seconds,
            'report_batch_item_failures' => @report_batch_item_failures,
            'enabled' => @enabled
          }.compact
        end
      end

      private

      def resolve_options(opts)
        sns_val = opts[:sns]
        sqs_val = opts[:sqs]
        sns_hash = sns_val.is_a?(Hash) && !cfn_intrinsic_hash?(sns_val) ? symbolize_keys(sns_val) : nil
        sqs_hash = sqs_val.is_a?(Hash) && !cfn_intrinsic_hash?(sqs_val) ? symbolize_keys(sqs_val) : nil

        inferred_type = opts[:type] || (!sns_val.nil? || !opts[:topic].nil? || !opts[:topic_arn].nil? ? :sns : :sqs)

        resolved_topic = opts[:topic] || opts[:topic_arn] ||
                         (sns_hash ? (sns_hash[:topic] || sns_hash[:topic_arn]) : sns_val)
        resolved_queue = opts[:queue] || (sqs_hash ? sqs_hash[:queue] : sqs_val)

        {
          type: inferred_type,
          queue: resolved_queue,
          topic: resolved_topic,
          batch_size: opts[:batch_size] || (sqs_hash && sqs_hash[:batch_size]),
          maximum_batching_window_in_seconds: opts[:maximum_batching_window_in_seconds] ||
            (sqs_hash && (sqs_hash[:maximum_batching_window_in_seconds] || sqs_hash[:batch_window])),
          report_batch_item_failures: opts[:report_batch_item_failures] ||
            (sqs_hash && sqs_hash[:report_batch_item_failures]) || false,
          filter_policy: opts[:filter_policy] || (sns_hash && sns_hash[:filter_policy]),
          filter_policy_scope: opts[:filter_policy_scope] || (sns_hash && sns_hash[:filter_policy_scope]),
          enabled: resolve_enabled_option(opts[:enabled], sns_hash, sqs_hash)
        }
      end

      def resolve_enabled_option(direct_enabled, sns_hash, sqs_hash)
        if sns_hash&.key?(:enabled)
          sns_hash[:enabled]
        elsif sqs_hash&.key?(:enabled)
          sqs_hash[:enabled]
        else
          direct_enabled
        end
      end

      def cfn_intrinsic_hash?(hash)
        hash.key?('Ref') || hash.key?(:Ref) || hash.key?(:ref) || hash.key?('ref') ||
          hash.keys.any? { |k| k.to_s.start_with?('Fn::') }
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_sym] = v
        end
      end

      def init_sqs_attributes(resolved)
        @queue = normalize_queue(resolved[:queue])
        @batch_size = normalize_batch_size(resolved[:batch_size])
        @maximum_batching_window_in_seconds = normalize_batching_window(resolved[:maximum_batching_window_in_seconds])
        @report_batch_item_failures = resolved[:report_batch_item_failures] ? true : false
        @topic = nil
        @filter_policy = nil
        @filter_policy_scope = nil
      end

      def init_sns_attributes(resolved)
        @topic = normalize_topic(resolved[:topic])
        @filter_policy = normalize_filter_policy(resolved[:filter_policy])
        @filter_policy_scope = normalize_filter_policy_scope(resolved[:filter_policy_scope])
        @queue = nil
        @batch_size = nil
        @maximum_batching_window_in_seconds = nil
        @report_batch_item_failures = false
      end

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

      def normalize_topic(topic_val)
        if topic_val.nil? ||
           (topic_val.is_a?(Hash) && topic_val.empty?) ||
           (!topic_val.is_a?(Hash) && !topic_val.respond_to?(:name) && topic_val.to_s.strip.empty?)
          raise ArgumentError, 'Topic must be specified for SNS event source.'
        end

        if topic_val.is_a?(Symbol) || topic_val.respond_to?(:name)
          topic_val
        elsif topic_val.is_a?(Hash)
          deep_stringify_and_freeze(topic_val)
        else
          topic_val.to_s.strip.freeze
        end
      end

      def normalize_filter_policy(policy)
        return nil if policy.nil?

        raise ArgumentError, "Filter policy must be a Hash, got #{policy.class}." unless policy.is_a?(Hash)
        raise ArgumentError, 'Filter policy cannot be empty.' if policy.empty?

        deep_stringify_and_freeze(policy)
      end

      def normalize_filter_policy_scope(scope)
        return nil if scope.nil?

        normalized = case scope.to_s.strip
                     when 'MessageAttributes', 'message_attributes'
                       'MessageAttributes'
                     when 'MessageBody', 'message_body'
                       'MessageBody'
                     else
                       raise ArgumentError,
                             "Invalid filter_policy_scope '#{scope}'. " \
                             "Valid scopes: #{VALID_FILTER_POLICY_SCOPES.join(', ')}"
                     end
        normalized.freeze
      end

      def deep_stringify_and_freeze(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), memo|
            memo[k.to_s.freeze] = deep_stringify_and_freeze(v)
          end.freeze
        when Array
          obj.map { |v| deep_stringify_and_freeze(v) }.freeze
        when Symbol
          obj.to_s.freeze
        when String
          obj.dup.freeze
        else
          obj
        end
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
