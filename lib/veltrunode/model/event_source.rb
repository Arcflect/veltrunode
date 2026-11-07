# frozen_string_literal: true

module Veltrunode
  module Model
    # Lambda 関数のイベントソース（SQS / DynamoDB Streams / Kinesis Data Streams / SNS / S3 / EventBridge Rule）を表す値オブジェクト
    class EventSource
      SUPPORTED_TYPES = %i[sqs sns s3 dynamodb_stream kinesis_stream rule].freeze
      VALID_FILTER_POLICY_SCOPES = %w[MessageAttributes MessageBody].freeze
      DEFAULT_S3_EVENTS = ['s3:ObjectCreated:*'].freeze
      VALID_S3_FILTER_KEYS = %w[prefix suffix].freeze
      VALID_STARTING_POSITIONS = %w[LATEST TRIM_HORIZON].freeze
      DEFAULT_STARTING_POSITION = 'LATEST'
      VALID_RULE_STATES = %i[enabled disabled].freeze

      attr_reader :type, :queue, :batch_size, :maximum_batching_window_in_seconds, :report_batch_item_failures,
                  :topic, :filter_policy, :filter_policy_scope, :bucket, :events, :filter,
                  :stream, :starting_position, :parallelization_factor, :bisect_batch_on_function_error,
                  :name, :bus, :pattern, :state, :description, :input, :target_function

      alias dynamodb_stream stream
      alias kinesis_stream stream
      alias stream_arn stream
      alias event_bus bus
      alias event_bus_name bus
      alias event_pattern pattern

      # @param type [Symbol, String, nil] イベントソース種別 (:sqs, :sns, :s3, :dynamodb_stream, :rule)
      # @param queue [String, Symbol, nil] SQS キュー名または ARN
      # @param sqs [String, Symbol, Hash, nil] SQS キュー指定またはオプションハッシュ
      # @param topic [String, Symbol, Hash, DSL::Reference, nil] SNS トピック ARN または参照
      # @param topic_arn [String, Symbol, Hash, DSL::Reference, nil] SNS トピック ARN または参照 (topic のエイリアス)
      # @param sns [String, Symbol, Hash, DSL::Reference, nil] SNS トピック指定またはオプションハッシュ
      # @param bucket [String, Symbol, Hash, DSL::Reference, nil] S3 バケット名、ARN または参照
      # @param s3 [String, Symbol, Hash, DSL::Reference, nil] S3 バケット指定またはオプションハッシュ
      # @param events [Array<String>, String, nil] S3 イベント種別 (デフォルト: ['s3:ObjectCreated:*'])
      # @param event [Array<String>, String, nil] S3 イベント種別 (events のエイリアス)
      # @param filter [Hash, nil] S3 通知フィルタ ({ prefix: '...', suffix: '...' })
      # @param prefix [String, nil] S3 オブジェクトキープレフィックスフィルタ
      # @param suffix [String, nil] S3 オブジェクトキーサフィックスフィルタ
      # @param stream [String, Symbol, Hash, DSL::Reference, nil] DynamoDB Streams ARN または参照
      # @param stream_arn [String, Symbol, Hash, DSL::Reference, nil] DynamoDB Streams ARN または参照 (stream のエイリアス)
      # @param dynamodb_stream [String, Symbol, Hash, DSL::Reference, nil] DynamoDB Streams 指定またはオプションハッシュ
      # @param starting_position [Symbol, String, nil] ストリーム読み取り開始位置 (:latest / :trim_horizon)
      # @param rule [Hash, Symbol, String, nil] EventBridge ルール指定またはオプションハッシュ
      # @param name [String, Symbol, nil] EventBridge ルール名（識別子）
      # @param bus [String, Symbol, Hash, DSL::Reference, nil] EventBridge イベントバス名、ARN または参照
      # @param event_bus [String, Symbol, Hash, DSL::Reference, nil] bus のエイリアス
      # @param pattern [Hash, nil] EventBridge イベントパターン ({ source: [...], 'detail-type': [...] })
      # @param event_pattern [Hash, nil] pattern のエイリアス
      # @param state [Symbol, String, nil] ルール状態 (:enabled / :disabled)
      # @param description [String, nil] ルールの説明文
      # @param input [Hash, Array, String, nil] ターゲットへの定数 JSON インプット
      # @param target [String, Symbol, nil] ターゲット関数名（Application レベル定義時）
      # @param target_function [String, Symbol, nil] target のエイリアス
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
        bucket: nil,
        s3: nil,
        events: nil,
        event: nil,
        filter: nil,
        prefix: nil,
        suffix: nil,
        stream: nil,
        stream_arn: nil,
        dynamodb_stream: nil,
        kinesis_stream: nil,
        kinesis: nil,
        starting_position: nil,
        parallelization_factor: nil,
        bisect_batch_on_function_error: nil,
        bisect_batch: nil,
        rule: nil,
        name: nil,
        bus: nil,
        event_bus: nil,
        pattern: nil,
        event_pattern: nil,
        state: nil,
        description: nil,
        input: nil,
        target: nil,
        target_function: nil,
        batch_size: nil,
        maximum_batching_window_in_seconds: nil,
        report_batch_item_failures: false,
        filter_policy: nil,
        filter_policy_scope: nil,
        enabled: true
      )
        resolved = resolve_options(
          type: type, queue: queue, sqs: sqs, topic: topic, topic_arn: topic_arn, sns: sns,
          bucket: bucket, s3: s3, events: events, event: event, filter: filter, prefix: prefix, suffix: suffix,
          stream: stream, stream_arn: stream_arn, dynamodb_stream: dynamodb_stream,
          kinesis_stream: kinesis_stream || kinesis,
          starting_position: starting_position,
          parallelization_factor: parallelization_factor,
          bisect_batch_on_function_error: bisect_batch_on_function_error.nil? ? bisect_batch : bisect_batch_on_function_error, # rubocop:disable Layout/LineLength
          rule: rule, name: name, bus: bus, event_bus: event_bus, pattern: pattern, event_pattern: event_pattern,
          state: state, description: description, input: input, target: target, target_function: target_function,
          batch_size: batch_size, maximum_batching_window_in_seconds: maximum_batching_window_in_seconds,
          report_batch_item_failures: report_batch_item_failures, filter_policy: filter_policy,
          filter_policy_scope: filter_policy_scope, enabled: enabled
        )

        @type = normalize_type(resolved[:type])
        reset_attributes
        case @type
        when :sqs
          init_sqs_attributes(resolved)
        when :sns
          init_sns_attributes(resolved)
        when :s3
          init_s3_attributes(resolved)
        when :dynamodb_stream, :kinesis_stream
          init_stream_attributes(resolved)
        when :rule
          init_rule_attributes(resolved)
        end
        if @type != :rule
          @enabled = resolved[:enabled].nil? || resolved[:enabled]
          @state = @enabled ? :enabled : :disabled
        end
        freeze
      end

      def sqs?
        @type == :sqs
      end

      def sns?
        @type == :sns
      end

      def s3?
        @type == :s3
      end

      def dynamodb_stream?
        @type == :dynamodb_stream
      end

      def kinesis_stream?
        @type == :kinesis_stream
      end
      alias kinesis? kinesis_stream?

      def rule?
        @type == :rule
      end
      alias event_rule? rule?
      alias eventbridge? rule?

      def report_batch_item_failures?
        @report_batch_item_failures
      end

      def bisect_batch_on_function_error?
        @bisect_batch_on_function_error == true
      end

      def enabled?
        @enabled
      end

      def disabled?
        !@enabled
      end

      def cfn_state
        @state == :disabled ? 'DISABLED' : 'ENABLED'
      end

      def managed_bucket?
        return false unless s3? && @bucket

        !external_bucket?
      end

      def external_bucket?
        return false unless s3? && @bucket
        return true if (!@bucket.is_a?(Symbol) && @bucket.respond_to?(:name)) || @bucket.is_a?(Hash)

        @bucket.to_s.start_with?('arn:')
      end

      def filter_prefix
        @filter&.fetch('prefix', nil)
      end

      def filter_suffix
        @filter&.fetch('suffix', nil)
      end

      def filter_rules
        return [] unless @filter

        rules = []
        rules << { 'Name' => 'prefix', 'Value' => @filter['prefix'] } if @filter['prefix']
        rules << { 'Name' => 'suffix', 'Value' => @filter['suffix'] } if @filter['suffix']
        rules
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

      def bucket_identifier
        return nil if @bucket.nil?
        return @bucket.to_s if @bucket.is_a?(Symbol)
        return @bucket.name.to_s if @bucket.respond_to?(:name)

        if @bucket.is_a?(Hash)
          ref_val = @bucket['Ref'] || @bucket[:Ref] || @bucket[:ref] || @bucket['ref']
          return ref_val.to_s if ref_val

          get_att = @bucket['Fn::GetAtt'] || @bucket[:'Fn::GetAtt']
          return Array(get_att).first.to_s if get_att

          return nil
        end

        b_str = @bucket.to_s
        if b_str.start_with?('arn:')
          b_str.split(':').last
        else
          b_str
        end
      end

      def stream_identifier
        return nil if @stream.nil?
        return @stream.to_s if @stream.is_a?(Symbol)
        return @stream.name.to_s if @stream.respond_to?(:name)

        if @stream.is_a?(Hash)
          ref_val = @stream['Ref'] || @stream[:Ref] || @stream[:ref] || @stream['ref']
          return ref_val.to_s if ref_val

          get_att = @stream['Fn::GetAtt'] || @stream[:'Fn::GetAtt']
          return Array(get_att).first.to_s if get_att

          return nil
        end

        s_str = @stream.to_s
        if s_str =~ %r{:(?:table|stream)/([^/]+)}
          Regexp.last_match(1)
        elsif s_str.start_with?('arn:')
          s_str.split(':').last
        else
          s_str
        end
      end

      def bus_identifier
        return nil if @bus.nil?
        return @bus.to_s if @bus.is_a?(Symbol)
        return @bus.name.to_s if !@bus.is_a?(Symbol) && @bus.respond_to?(:name)

        if @bus.is_a?(Hash)
          ref_val = @bus['Ref'] || @bus[:Ref] || @bus[:ref] || @bus['ref']
          return ref_val.to_s if ref_val

          get_att = @bus['Fn::GetAtt'] || @bus[:'Fn::GetAtt']
          return Array(get_att).first.to_s if get_att

          return nil
        end

        b_str = @bus.to_s
        if b_str.start_with?('arn:')
          b_str.split('/').last.split(':').last
        else
          b_str
        end
      end

      def rule_identifier
        return @name.to_s if @name && !@name.to_s.strip.empty?

        bus_id = bus_identifier
        return nil if bus_id.nil? || bus_id.downcase == 'default'

        bus_id
      end

      def source_identifier
        case @type
        when :sqs then queue_identifier
        when :sns then topic_identifier
        when :s3 then bucket_identifier
        when :dynamodb_stream, :kinesis_stream then stream_identifier
        when :rule then rule_identifier
        end
      end

      def to_h
        case @type
        when :sns
          topic_val = !@topic.is_a?(Symbol) && @topic.respond_to?(:name) ? @topic.name.to_s : @topic
          {
            'type' => @type.to_s,
            'topic' => topic_val,
            'filter_policy' => @filter_policy,
            'filter_policy_scope' => @filter_policy_scope,
            'enabled' => @enabled
          }.compact
        when :s3
          bucket_val = !@bucket.is_a?(Symbol) && @bucket.respond_to?(:name) ? @bucket.name.to_s : @bucket
          {
            'type' => @type.to_s,
            'bucket' => bucket_val,
            'events' => @events,
            'filter' => @filter,
            'enabled' => @enabled
          }.compact
        when :dynamodb_stream, :kinesis_stream
          stream_val = !@stream.is_a?(Symbol) && @stream.respond_to?(:name) ? @stream.name.to_s : @stream
          {
            'type' => @type.to_s,
            'stream' => stream_val,
            'starting_position' => @starting_position,
            'batch_size' => @batch_size,
            'maximum_batching_window_in_seconds' => @maximum_batching_window_in_seconds,
            'parallelization_factor' => @parallelization_factor,
            'bisect_batch_on_function_error' => @bisect_batch_on_function_error,
            'report_batch_item_failures' => @report_batch_item_failures,
            'enabled' => @enabled
          }.compact
        when :rule
          bus_val = !@bus.is_a?(Symbol) && @bus.respond_to?(:name) ? @bus.name.to_s : @bus
          {
            'type' => @type.to_s,
            'name' => @name,
            'bus' => bus_val,
            'pattern' => @pattern,
            'state' => @state.to_s,
            'description' => @description,
            'input' => @input,
            'target_function' => @target_function,
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

      def reset_attributes
        @queue = nil
        @batch_size = nil
        @maximum_batching_window_in_seconds = nil
        @report_batch_item_failures = false
        @topic = nil
        @filter_policy = nil
        @filter_policy_scope = nil
        @bucket = nil
        @events = nil
        @filter = nil
        @stream = nil
        @starting_position = nil
        @parallelization_factor = nil
        @bisect_batch_on_function_error = nil
        @name = nil
        @bus = nil
        @pattern = nil
        @state = :enabled
        @description = nil
        @input = nil
        @target_function = nil
      end

      def resolve_options(opts)
        sns_val = opts[:sns]
        sqs_val = opts[:sqs]
        s3_val = opts[:s3]
        ddb_val = opts[:dynamodb_stream]
        kin_val = opts[:kinesis_stream]
        rule_val = opts[:rule]
        sns_hash = sns_val.is_a?(Hash) && !cfn_intrinsic_hash?(sns_val) ? symbolize_keys(sns_val) : nil
        sqs_hash = sqs_val.is_a?(Hash) && !cfn_intrinsic_hash?(sqs_val) ? symbolize_keys(sqs_val) : nil
        s3_hash = s3_val.is_a?(Hash) && !cfn_intrinsic_hash?(s3_val) ? symbolize_keys(s3_val) : nil
        ddb_hash = ddb_val.is_a?(Hash) && !cfn_intrinsic_hash?(ddb_val) ? symbolize_keys(ddb_val) : nil
        kin_hash = kin_val.is_a?(Hash) && !cfn_intrinsic_hash?(kin_val) ? symbolize_keys(kin_val) : nil
        rule_hash = rule_val.is_a?(Hash) && !cfn_intrinsic_hash?(rule_val) ? symbolize_keys(rule_val) : nil
        stream_hash = kin_hash || ddb_hash

        inferred_type = infer_type(
          opts,
          sns_val: sns_val, s3_val: s3_val, ddb_val: ddb_val, kin_val: kin_val, rule_val: rule_val
        )

        resolved_topic = opts[:topic] || opts[:topic_arn] ||
                         (sns_hash ? (sns_hash[:topic] || sns_hash[:topic_arn]) : sns_val)
        resolved_queue = opts[:queue] || (sqs_hash ? sqs_hash[:queue] : sqs_val)
        resolved_bucket = opts[:bucket] || (s3_hash ? s3_hash[:bucket] : s3_val)
        resolved_stream = opts[:stream] || opts[:stream_arn] ||
                          (if stream_hash
                             stream_hash[:stream] || stream_hash[:stream_arn] || stream_hash[:arn]
                           else
                             kin_val || ddb_val
                           end)
        resolved_bus = opts[:bus] || opts[:event_bus] ||
                       (rule_hash && (rule_hash[:bus] || rule_hash[:event_bus] || rule_hash[:event_bus_name]))
        resolved_pattern = opts[:pattern] || opts[:event_pattern] ||
                           (rule_hash && (rule_hash[:pattern] || rule_hash[:event_pattern]))
        resolved_name = opts[:name] || (rule_hash ? rule_hash[:name] : rule_val)
        resolved_bisect = if !opts[:bisect_batch_on_function_error].nil?
                            opts[:bisect_batch_on_function_error]
                          elsif stream_hash && !stream_hash[:bisect_batch_on_function_error].nil?
                            stream_hash[:bisect_batch_on_function_error]
                          elsif stream_hash && !stream_hash[:bisect_batch].nil?
                            stream_hash[:bisect_batch]
                          end

        {
          type: inferred_type,
          queue: resolved_queue,
          topic: resolved_topic,
          bucket: resolved_bucket,
          events: resolve_s3_events_option(opts, s3_hash),
          filter: resolve_s3_filter_option(opts, s3_hash),
          stream: resolved_stream,
          starting_position: opts[:starting_position] || (stream_hash && stream_hash[:starting_position]),
          parallelization_factor: opts[:parallelization_factor] ||
            (stream_hash && stream_hash[:parallelization_factor]),
          bisect_batch_on_function_error: resolved_bisect,
          name: resolved_name,
          bus: resolved_bus,
          pattern: resolved_pattern,
          state: opts[:state] || (rule_hash && rule_hash[:state]),
          description: opts[:description] || (rule_hash && rule_hash[:description]),
          input: opts[:input] || (rule_hash && rule_hash[:input]),
          target_function: opts[:target] || opts[:target_function] ||
            (rule_hash && (rule_hash[:target] || rule_hash[:target_function])),
          batch_size: opts[:batch_size] || (sqs_hash && sqs_hash[:batch_size]) ||
            (stream_hash && stream_hash[:batch_size]),
          maximum_batching_window_in_seconds: opts[:maximum_batching_window_in_seconds] ||
            (sqs_hash && (sqs_hash[:maximum_batching_window_in_seconds] || sqs_hash[:batch_window])) ||
            (stream_hash && (stream_hash[:maximum_batching_window_in_seconds] || stream_hash[:batch_window])),
          report_batch_item_failures: opts[:report_batch_item_failures] ||
            (sqs_hash && sqs_hash[:report_batch_item_failures]) ||
            (stream_hash && stream_hash[:report_batch_item_failures]) || false,
          filter_policy: opts[:filter_policy] || (sns_hash && sns_hash[:filter_policy]),
          filter_policy_scope: opts[:filter_policy_scope] || (sns_hash && sns_hash[:filter_policy_scope]),
          enabled: resolve_enabled_option(opts[:enabled], sns_hash, sqs_hash, s3_hash, ddb_hash, kin_hash, rule_hash)
        }
      end

      def infer_type(opts, sns_val:, s3_val:, ddb_val: nil, kin_val: nil, rule_val: nil)
        return opts[:type] if opts[:type]
        if !rule_val.nil? || !opts[:pattern].nil? || !opts[:event_pattern].nil? ||
           !opts[:bus].nil? || !opts[:event_bus].nil?
          return :rule
        end
        return :kinesis_stream unless kin_val.nil?
        return :dynamodb_stream if !ddb_val.nil? || !opts[:stream].nil? || !opts[:stream_arn].nil?
        return :s3 if !s3_val.nil? || !opts[:bucket].nil?
        return :sns if !sns_val.nil? || !opts[:topic].nil? || !opts[:topic_arn].nil?

        :sqs
      end

      def resolve_s3_events_option(opts, s3_hash)
        return opts[:events] unless opts[:events].nil?
        return opts[:event] unless opts[:event].nil?
        return nil unless s3_hash

        s3_hash.key?(:events) ? s3_hash[:events] : s3_hash[:event]
      end

      def resolve_s3_filter_option(opts, s3_hash)
        raw_filter = opts[:filter] || (s3_hash && s3_hash[:filter])
        prefix = opts[:prefix] || (s3_hash && s3_hash[:prefix])
        suffix = opts[:suffix] || (s3_hash && s3_hash[:suffix])

        return raw_filter if prefix.nil? && suffix.nil?
        return raw_filter unless raw_filter.nil? || raw_filter.is_a?(Hash)

        merged = (raw_filter || {}).dup
        merged[:prefix] = prefix unless prefix.nil?
        merged[:suffix] = suffix unless suffix.nil?
        merged
      end

      def resolve_enabled_option(direct_enabled, *hashes)
        hashes.compact.each do |h|
          return h[:enabled] if h.key?(:enabled)
        end
        direct_enabled
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
      end

      def init_sns_attributes(resolved)
        @topic = normalize_topic(resolved[:topic])
        @filter_policy = normalize_filter_policy(resolved[:filter_policy])
        @filter_policy_scope = normalize_filter_policy_scope(resolved[:filter_policy_scope])
      end

      def init_s3_attributes(resolved)
        @bucket = normalize_bucket(resolved[:bucket])
        @events = normalize_s3_events(resolved[:events])
        @filter = normalize_s3_filter(resolved[:filter])
      end

      def init_stream_attributes(resolved)
        @stream = normalize_stream(resolved[:stream])
        @starting_position = normalize_starting_position(resolved[:starting_position])
        @batch_size = normalize_batch_size(resolved[:batch_size])
        @maximum_batching_window_in_seconds = normalize_batching_window(resolved[:maximum_batching_window_in_seconds])
        @parallelization_factor = normalize_parallelization_factor(resolved[:parallelization_factor])
        @bisect_batch_on_function_error = normalize_boolean(resolved[:bisect_batch_on_function_error])
        @report_batch_item_failures = resolved[:report_batch_item_failures] ? true : false
      end

      def init_rule_attributes(resolved)
        @name = normalize_optional_string(resolved[:name])
        @bus = normalize_rule_bus(resolved[:bus])
        @pattern = normalize_rule_pattern(resolved[:pattern])
        @state = normalize_rule_state(resolved[:state], resolved[:enabled])
        @enabled = @state == :enabled
        @description = normalize_optional_string(resolved[:description])
        @input = deep_stringify_and_freeze(resolved[:input]) unless resolved[:input].nil?
        @target_function = normalize_optional_string(resolved[:target_function])
      end

      def normalize_optional_string(val)
        return nil if val.nil?

        str = val.to_s.strip
        str.empty? ? nil : str.freeze
      end

      def normalize_type(type_val)
        sym = type_val.to_s.downcase.to_sym
        sym = :dynamodb_stream if %i[dynamodb_streams dynamodb].include?(sym)
        sym = :kinesis_stream if %i[kinesis kinesis_streams kinesis_data_stream kinesis_data_streams].include?(sym)
        sym = :rule if %i[eventbridge event_bridge events event_rule].include?(sym)
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
           (!topic_val.is_a?(Hash) && topic_val.to_s.strip.empty?)
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

      def normalize_bucket(bucket_val)
        if bucket_val.nil? ||
           (bucket_val.is_a?(Hash) && bucket_val.empty?) ||
           (!bucket_val.is_a?(Hash) && bucket_val.to_s.strip.empty?)
          raise ArgumentError, 'Bucket must be specified for S3 event source.'
        end

        if bucket_val.is_a?(Symbol) || bucket_val.respond_to?(:name)
          bucket_val
        elsif bucket_val.is_a?(Hash)
          deep_stringify_and_freeze(bucket_val)
        else
          bucket_val.to_s.strip.freeze
        end
      end

      def normalize_s3_events(events_val)
        return DEFAULT_S3_EVENTS if events_val.nil?

        if events_val.is_a?(Array) && events_val.empty?
          raise ArgumentError, 'Events cannot be empty for S3 event source.'
        end

        list = Array(events_val).map { |e| e.to_s.strip }.reject(&:empty?)
        raise ArgumentError, 'Events cannot be empty for S3 event source.' if list.empty?

        list.each do |ev|
          unless ev.start_with?('s3:')
            raise ArgumentError, "Invalid S3 event '#{ev}'. S3 event names must start with 's3:'."
          end
        end

        list.map(&:freeze).freeze
      end

      def normalize_s3_filter(filter_val)
        return nil if filter_val.nil?

        raise ArgumentError, "Filter must be a Hash, got #{filter_val.class}." unless filter_val.is_a?(Hash)
        return nil if filter_val.empty?

        unknown_keys = filter_val.keys.map(&:to_s) - VALID_S3_FILTER_KEYS
        unless unknown_keys.empty?
          raise ArgumentError,
                "Unsupported S3 filter keys: #{unknown_keys.join(', ')}. " \
                "Supported keys: #{VALID_S3_FILTER_KEYS.join(', ')}"
        end

        prefix_val = filter_val[:prefix] || filter_val['prefix']
        suffix_val = filter_val[:suffix] || filter_val['suffix']

        res = {}
        res['prefix'] = prefix_val.to_s.freeze if prefix_val && !prefix_val.to_s.empty?
        res['suffix'] = suffix_val.to_s.freeze if suffix_val && !suffix_val.to_s.empty?
        res.empty? ? nil : res.freeze
      end

      def normalize_stream(stream_val)
        if stream_val.nil? ||
           (stream_val.is_a?(Hash) && stream_val.empty?) ||
           (!stream_val.is_a?(Hash) && stream_val.to_s.strip.empty?)
          stream_label = @type == :kinesis_stream ? 'Kinesis' : 'DynamoDB'
          raise ArgumentError, "Stream must be specified for #{stream_label} Stream event source."
        end

        if stream_val.is_a?(Symbol) || stream_val.respond_to?(:name)
          stream_val
        elsif stream_val.is_a?(Hash)
          deep_stringify_and_freeze(stream_val)
        else
          stream_val.to_s.strip.freeze
        end
      end

      def normalize_starting_position(pos_val)
        return DEFAULT_STARTING_POSITION if pos_val.nil?

        normalized = pos_val.to_s.strip.upcase.tr('-', '_')
        unless VALID_STARTING_POSITIONS.include?(normalized)
          raise ArgumentError,
                "Invalid starting_position '#{pos_val}'. " \
                "Valid positions: #{VALID_STARTING_POSITIONS.join(', ')}"
        end

        normalized.freeze
      end

      def normalize_rule_bus(bus_val)
        return nil if bus_val.nil?

        if (bus_val.is_a?(Hash) && bus_val.empty?) ||
           (!bus_val.is_a?(Hash) && bus_val.to_s.strip.empty?)
          raise ArgumentError, 'Event bus cannot be empty for EventBridge rule.'
        end

        if bus_val.is_a?(Symbol) || bus_val.respond_to?(:name)
          bus_val
        elsif bus_val.is_a?(Hash)
          deep_stringify_and_freeze(bus_val)
        else
          bus_val.to_s.strip.freeze
        end
      end

      def normalize_rule_pattern(pattern_val)
        if pattern_val.nil? || (pattern_val.is_a?(Hash) && pattern_val.empty?)
          raise ArgumentError, 'Event pattern must be specified for EventBridge rule.'
        end
        raise ArgumentError, "Event pattern must be a Hash, got #{pattern_val.class}." unless pattern_val.is_a?(Hash)

        deep_stringify_and_freeze(pattern_val)
      end

      def normalize_rule_state(state_val, enabled_val)
        if state_val.nil?
          return enabled_val == false ? :disabled : :enabled
        end

        sym = state_val.to_s.strip.downcase.to_sym
        unless VALID_RULE_STATES.include?(sym)
          raise ArgumentError,
                "Invalid rule state '#{state_val}'. Valid states: #{VALID_RULE_STATES.join(', ')}"
        end

        sym
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

      def normalize_parallelization_factor(factor)
        return nil if factor.nil?

        int_val = factor.to_i
        unless (1..10).cover?(int_val)
          raise ArgumentError, "Parallelization factor must be between 1 and 10, got #{factor}."
        end

        int_val
      end

      def normalize_boolean(val)
        return nil if val.nil?

        val ? true : false
      end
    end
  end
end
