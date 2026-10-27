# frozen_string_literal: true

require 'json'
require 'time'

module Veltrunode
  module AWS
    # CloudWatch Logs ログストリーミングに関するエラー
    class LogStreamError < Veltrunode::Error
      attr_reader :log_group_name, :original_error

      def initialize(message, log_group_name: nil, original_error: nil)
        super(message)
        @log_group_name = log_group_name
        @original_error = original_error
      end
    end

    # 個別のログイベントを表す値オブジェクト
    class LogEvent
      attr_reader :event_id, :timestamp, :message, :log_group_name, :function_name, :ingestion_time

      def initialize(
        event_id:,
        timestamp:,
        message:,
        log_group_name:,
        function_name: nil,
        ingestion_time: nil
      )
        @event_id = event_id.to_s.freeze
        @timestamp = timestamp.to_i
        @message = message.to_s.freeze
        @log_group_name = log_group_name.to_s.freeze
        @function_name = (function_name || self.class.infer_function_name(log_group_name)).to_s.freeze
        @ingestion_time = ingestion_time&.to_i
        freeze
      end

      def self.infer_function_name(log_group_name)
        if log_group_name.start_with?('/aws/lambda/')
          log_group_name.sub(%r{\A/aws/lambda/}, '')
        else
          log_group_name
        end
      end

      def iso_timestamp
        Time.at(@timestamp / 1000.0).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
      end

      def to_h
        {
          'event_id' => @event_id,
          'timestamp' => @timestamp,
          'iso_timestamp' => iso_timestamp,
          'log_group_name' => @log_group_name,
          'function_name' => @function_name,
          'message' => @message
        }
      end

      def to_json(*_args)
        to_h.to_json
      end
    end

    # CloudWatch Logs Live Tail / FilterLogEvents を用いてリアルタイムにログを追跡・表示するクラス
    class LogStreamer
      DEFAULT_POLL_INTERVAL = 2.0
      DEFAULT_SINCE_SECONDS = 300 # 5分前
      MAX_SEEN_CACHE_SIZE = 10_000

      attr_reader :targets, :region, :filter_pattern, :since_seconds, :follow,
                  :poll_interval, :output, :format, :prefix_function_name

      # @param targets [Array<String>, String] 関数名またはロググループ名
      # @param client [Aws::CloudWatchLogs::Client, nil] テスト用クライアント
      # @param region [String, nil] AWS リージョン
      # @param filter_pattern [String, nil] CloudWatch Logs フィルタパターン
      # @param since [Integer, String, nil] 過去ログ取得開始秒数（または 5m, 1h などの文字列）
      # @param start_time [Integer, nil] 取得開始エポックミリ秒
      # @param follow [Boolean] リアルタイム追跡するかどうか（デフォルト: true）
      # @param poll_interval [Float] ポーリング間隔秒（デフォルト: 2.0）
      # @param output [IO] ログ出力先（デフォルト: $stdout）
      # @param format [Symbol] 出力フォーマット (:text または :json)
      # @param prefix_function_name [Boolean, nil] 出力に関数名プレフィックスを付けるか
      def initialize(
        targets:,
        client: nil,
        region: nil,
        filter_pattern: nil,
        since: DEFAULT_SINCE_SECONDS,
        start_time: nil,
        follow: true,
        poll_interval: DEFAULT_POLL_INTERVAL,
        output: $stdout,
        format: :text,
        prefix_function_name: nil
      )
        @raw_targets = Array(targets).flatten.map(&:to_s).reject { |t| t.strip.empty? }
        raise ArgumentError, 'At least one target function or log group must be specified.' if @raw_targets.empty?

        @targets = normalize_targets(@raw_targets)
        @client = client
        @region = resolve_region(region)
        @filter_pattern = filter_pattern&.strip&.empty? ? nil : filter_pattern
        @since_seconds = parse_since(since)
        @start_time = start_time || calculate_default_start_time
        @follow = follow.nil? || follow
        @poll_interval = poll_interval.to_f
        @output = output
        @format = format.to_sym
        @prefix_function_name = prefix_function_name.nil? ? (@targets.size > 1) : prefix_function_name

        @seen_event_ids = Set.new
        @seen_queue = []
        @stopped = false
        @warned_missing_log_groups = Set.new
      end

      # ログストリーミングを開始します
      # @yieldparam [LogEvent] event コールバック（省略時は標準出力/指定ストリームへ出力）
      # @return [Integer] 出力したイベント総数
      def stream(&)
        total_events_count = 0

        loop do
          break if @stopped

          events = fetch_batch
          events.each do |event|
            if block_given?
              yield event
            else
              print_event(event)
            end
            total_events_count += 1
          end

          break unless @follow
          break if @stopped

          sleep(@poll_interval)
        end

        total_events_count
      end

      # ストリーミングを安全に停止します
      def stop!
        @stopped = true
      end

      # 現在停止要求が出ているかどうか
      def stopped?
        @stopped
      end

      # 1回のポーリングバッチで新規イベントを取得して重複排除・ソートして返します
      # @return [Array<LogEvent>]
      def fetch_batch
        all_events = []

        @targets.each do |target_info|
          events = fetch_events_for_target(target_info)
          all_events.concat(events)
        end

        # タイムスタンプ順（同じタイムスタンプの場合は ingestion_time 順）にソート
        all_events.sort_by! { |e| [e.timestamp, e.ingestion_time || 0] }

        # 重複排除
        new_events = []
        all_events.each do |ev|
          next if @seen_event_ids.include?(ev.event_id)

          record_seen_event(ev.event_id)
          new_events << ev
        end

        # 次回ポーリング用の start_time 更新
        if new_events.any?
          latest_ts = new_events.map(&:timestamp).max
          # 複数イベントがミリ秒単位で同時に発生する可能性があるため、最新 timestamp - 1秒
          @start_time = [latest_ts - 1000, @start_time].max
        end

        new_events
      end

      # イベントをフォーマットして出力ストリームに書き込みます
      def print_event(event)
        if @format == :json
          @output.puts event.to_json
        else
          line = format_text_event(event)
          @output.puts line
        end
        @output.flush if @output.respond_to?(:flush)
      end

      # テキスト形式のフォーマット
      def format_text_event(event)
        time_part = "[#{event.iso_timestamp}]"
        prefix_part = @prefix_function_name ? "[#{event.function_name}] " : ''
        # メッセージ末尾の不要な改行をトリム
        clean_message = event.message.to_s.sub(/\r?\n\z/, '')
        "#{time_part} #{prefix_part}#{clean_message}"
      end

      # 期間指定文字列 (5m, 1h, 30s, 1d 等) を秒数にパース
      def self.parse_since_duration(val)
        return DEFAULT_SINCE_SECONDS if val.nil?
        return val.to_i if val.is_a?(Numeric)

        str = val.to_s.strip
        return DEFAULT_SINCE_SECONDS if str.empty?

        case str
        when /\A(\d+)\z/, /\A(\d+)\s*s(?:ec(?:onds?)?)?\z/i
          ::Regexp.last_match(1).to_i
        when /\A(\d+)\s*m(?:in(?:utes?)?)?\z/i
          ::Regexp.last_match(1).to_i * 60
        when /\A(\d+)\s*h(?:ours?)?\z/i
          ::Regexp.last_match(1).to_i * 3600
        when /\A(\d+)\s*d(?:ays?)?\z/i
          ::Regexp.last_match(1).to_i * 86_400
        else
          raise ArgumentError, "Invalid since format '#{val}'. Expected duration like 5m, 1h, 30s, or seconds."
        end
      end

      private

      def parse_since(val)
        self.class.parse_since_duration(val)
      end

      def calculate_default_start_time
        # 現在時刻から since_seconds 秒前をエポックミリ秒に変換
        ((Time.now.to_f - @since_seconds) * 1000).to_i
      end

      def normalize_targets(raw_targets)
        raw_targets.map do |raw|
          if raw.start_with?('/')
            log_group_name = raw
            fn_name = LogEvent.infer_function_name(raw)
          else
            log_group_name = "/aws/lambda/#{raw}"
            fn_name = raw
          end
          {
            log_group_name: log_group_name.freeze,
            function_name: fn_name.freeze
          }.freeze
        end.freeze
      end

      def resolve_region(provided_region)
        provided_region ||
          ENV['AWS_REGION'] ||
          ENV['AWS_DEFAULT_REGION'] ||
          'us-east-1'
      end

      def client
        @client ||= resolve_cloudwatch_client
      end

      def resolve_cloudwatch_client
        require 'aws-sdk-cloudwatchlogs' unless defined?(::Aws::CloudWatchLogs::Client)
        ::Aws::CloudWatchLogs::Client.new(region: @region)
      rescue LoadError => e
        raise LogStreamError,
              "AWS SDK (aws-sdk-cloudwatchlogs) is not available: #{e.message}. Please install aws-sdk-cloudwatchlogs."
      rescue StandardError => e
        raise LogStreamError.new(
          "Failed to initialize AWS CloudWatch Logs client: #{e.message}",
          original_error: e
        )
      end

      def fetch_events_for_target(target_info)
        params = {
          log_group_name: target_info[:log_group_name],
          start_time: @start_time
        }
        params[:filter_pattern] = @filter_pattern if @filter_pattern

        events = []
        next_token = nil
        page_count = 0
        max_pages_per_batch = 10

        loop do
          req_params = next_token ? params.merge(next_token: next_token) : params
          response = client.filter_log_events(req_params)
          page_count += 1

          if response.events && !response.events.empty?
            response.events.each do |ev|
              events << LogEvent.new(
                event_id: ev.event_id,
                timestamp: ev.timestamp,
                message: ev.message,
                log_group_name: target_info[:log_group_name],
                function_name: target_info[:function_name],
                ingestion_time: ev.respond_to?(:ingestion_time) ? ev.ingestion_time : nil
              )
            end
          end

          next_token = response.next_token
          break if next_token.nil? || next_token.empty? || page_count >= max_pages_per_batch
        end

        events
      rescue StandardError => e
        handle_fetch_error(e, target_info)
      end

      def handle_fetch_error(error, target_info)
        lg = target_info[:log_group_name]
        error_class_name = error.class.name

        # ResourceNotFoundException: ロググループが存在しない場合
        if error_class_name.include?('ResourceNotFoundException') || error.message.include?('ResourceNotFound')
          unless @warned_missing_log_groups.include?(lg)
            @warned_missing_log_groups << lg
            msg = "[WARN] Log group '#{lg}' does not exist yet. Waiting for function invocations..."
            if @format == :json
              @output.puts({ 'warning' => msg, 'log_group_name' => lg }.to_json)
            else
              @output.puts msg
            end
            @output.flush if @output.respond_to?(:flush)
          end
          return []
        end

        # 認証エラーや権限エラー
        if error_class_name.include?('AccessDenied') ||
           error_class_name.include?('UnrecognizedClientException') ||
           error_class_name.include?('MissingCredentials')
          raise LogStreamError.new(
            "AWS authorization failed for log group '#{lg}': #{error.message}",
            log_group_name: lg,
            original_error: error
          )
        end

        # その他のエラー
        raise LogStreamError.new(
          "Failed to fetch logs for '#{lg}': #{error.message}",
          log_group_name: lg,
          original_error: error
        )
      end

      def record_seen_event(event_id)
        @seen_event_ids.add(event_id)
        @seen_queue.push(event_id)

        return unless @seen_queue.size > MAX_SEEN_CACHE_SIZE

        old_id = @seen_queue.shift
        @seen_event_ids.delete(old_id)
      end
    end
  end
end
