# frozen_string_literal: true

require 'json'
require 'time'

module Veltrunode
  module AWS
    # CloudWatch メトリクス取得に関するエラー
    class MetricsError < Veltrunode::Error
      attr_reader :function_name, :original_error

      def initialize(message, function_name: nil, original_error: nil)
        super(message)
        @function_name = function_name
        @original_error = original_error
      end
    end

    # 個別の関数メトリクスを表す値オブジェクト
    class FunctionMetrics
      attr_reader :function_name, :period, :start_time, :end_time,
                  :invocations, :errors, :error_rate, :throttles,
                  :duration_p50, :duration_p95, :duration_p99

      def initialize(
        function_name:,
        period:,
        start_time:,
        end_time:,
        invocations: 0,
        errors: 0,
        throttles: 0,
        duration_p50: nil,
        duration_p95: nil,
        duration_p99: nil
      )
        @function_name = function_name.to_s.freeze
        @period = period.to_s.freeze
        @start_time = start_time.is_a?(Time) ? start_time.utc : Time.parse(start_time.to_s).utc
        @end_time = end_time.is_a?(Time) ? end_time.utc : Time.parse(end_time.to_s).utc
        @invocations = invocations.to_i
        @errors = errors.to_i
        @throttles = throttles.to_i
        @error_rate = calculate_error_rate(@invocations, @errors)
        @duration_p50 = duration_p50&.to_f&.round(2)
        @duration_p95 = duration_p95&.to_f&.round(2)
        @duration_p99 = duration_p99&.to_f&.round(2)
        freeze
      end

      def to_h
        {
          'function_name' => @function_name,
          'period' => @period,
          'start_time' => @start_time.iso8601,
          'end_time' => @end_time.iso8601,
          'invocations' => @invocations,
          'errors' => @errors,
          'error_rate' => @error_rate,
          'throttles' => @throttles,
          'duration' => {
            'p50' => @duration_p50,
            'p95' => @duration_p95,
            'p99' => @duration_p99
          }
        }
      end

      def to_json(*_args)
        to_h.to_json
      end

      private

      def calculate_error_rate(invocations, errors)
        return 0.0 if invocations <= 0 || errors <= 0

        ((errors.to_f / invocations) * 100.0).round(2)
      end
    end

    # CloudWatch Metrics から Lambda 関数の主要メトリクスを取得・集計するクラス
    class MetricsCollector
      DEFAULT_PERIOD = '24h'

      attr_reader :region, :period, :duration_seconds

      # @param client [Aws::CloudWatch::Client, nil] CloudWatch クライアント
      # @param region [String, nil] AWS リージョン
      # @param period [String, Integer] 集計期間 ('1h', '24h', '7d' など)
      def initialize(client: nil, region: nil, period: DEFAULT_PERIOD)
        @client = client
        @region = resolve_region(region)
        @period = (period || DEFAULT_PERIOD).to_s
        @duration_seconds = self.class.parse_period_duration(@period)
      end

      # 指定した関数名のメトリクスを取得します
      # @param function_name [String] Lambda 関数名
      # @param now [Time, nil] 基準時刻 (テスト用)
      # @return [FunctionMetrics]
      def collect(function_name, now: nil)
        end_time = (now || Time.now).utc
        start_time = end_time - @duration_seconds

        queries = build_metric_queries(function_name, query_period)
        response = fetch_metric_data(queries, start_time, end_time, function_name)

        parse_metric_response(function_name, response, start_time, end_time)
      end

      # 複数の関数名のメトリクスを取得します
      # @param function_names [Array<String>] Lambda 関数名のリスト
      # @param now [Time, nil] 基準時刻 (テスト用)
      # @return [Array<FunctionMetrics>]
      def collect_all(function_names, now: nil)
        Array(function_names).map do |fn_name|
          collect(fn_name, now: now)
        end
      end

      # 期間文字列 ('1h', '24h', '7d' 等) を秒数にパース
      def self.parse_period_duration(val)
        return 86_400 if val.nil?
        return val.to_i if val.is_a?(Numeric)

        str = val.to_s.strip.downcase
        return 86_400 if str.empty?

        case str
        when /\A(\d+)\z/, /\A(\d+)\s*s(?:ec(?:onds?)?)?\z/
          ::Regexp.last_match(1).to_i
        when /\A(\d+)\s*m(?:in(?:utes?)?)?\z/
          ::Regexp.last_match(1).to_i * 60
        when /\A(\d+)\s*h(?:ours?)?\z/
          ::Regexp.last_match(1).to_i * 3600
        when /\A(\d+)\s*d(?:ays?)?\z/
          ::Regexp.last_match(1).to_i * 86_400
        else
          raise ArgumentError, "Invalid period format '#{val}'. Expected duration like 1h, 24h, or 7d."
        end
      end

      private

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
        require 'aws-sdk-cloudwatch' unless defined?(::Aws::CloudWatch::Client)
        ::Aws::CloudWatch::Client.new(region: @region)
      rescue LoadError => e
        raise MetricsError,
              "AWS SDK (aws-sdk-cloudwatch) is not available: #{e.message}. Please install aws-sdk-cloudwatch."
      rescue StandardError => e
        raise MetricsError.new(
          "Failed to initialize AWS CloudWatch client: #{e.message}",
          original_error: e
        )
      end

      # CloudWatch Metrics のクエリ period (秒)
      # 期間に応じて適切な集計単位を選択 (最大 86400 秒)
      def query_period
        if @duration_seconds <= 3600
          3600
        else
          [@duration_seconds, 86_400].min
        end
      end

      def build_metric_queries(function_name, q_period)
        dimensions = [{ name: 'FunctionName', value: function_name }]
        [
          build_stat_query('invocations', 'AWS/Lambda', 'Invocations', dimensions, q_period, 'Sum'),
          build_stat_query('errors', 'AWS/Lambda', 'Errors', dimensions, q_period, 'Sum'),
          build_stat_query('throttles', 'AWS/Lambda', 'Throttles', dimensions, q_period, 'Sum'),
          build_stat_query('duration_p50', 'AWS/Lambda', 'Duration', dimensions, q_period, 'p50'),
          build_stat_query('duration_p95', 'AWS/Lambda', 'Duration', dimensions, q_period, 'p95'),
          build_stat_query('duration_p99', 'AWS/Lambda', 'Duration', dimensions, q_period, 'p99')
        ]
      end

      def build_stat_query(id, namespace, metric_name, dimensions, q_period, stat)
        {
          id: id,
          metric_stat: {
            metric: {
              namespace: namespace,
              metric_name: metric_name,
              dimensions: dimensions
            },
            period: q_period,
            stat: stat
          },
          return_data: true
        }
      end

      def fetch_metric_data(queries, start_time, end_time, function_name)
        params = {
          metric_data_queries: queries,
          start_time: start_time,
          end_time: end_time
        }
        client.get_metric_data(params)
      rescue StandardError => e
        error_class_name = e.class.name
        if error_class_name.include?('AccessDenied') ||
           error_class_name.include?('UnrecognizedClientException') ||
           error_class_name.include?('MissingCredentials')
          raise MetricsError.new(
            "AWS authorization failed for metrics of '#{function_name}': #{e.message}",
            function_name: function_name,
            original_error: e
          )
        end

        raise MetricsError.new(
          "Failed to fetch metrics for '#{function_name}': #{e.message}",
          function_name: function_name,
          original_error: e
        )
      end

      def parse_metric_response(function_name, response, start_time, end_time)
        results_by_id = {}
        response.metric_data_results&.each do |res|
          results_by_id[res.id] = res.values || []
        end

        invocations = aggregate_sum(results_by_id['invocations'])
        errors = aggregate_sum(results_by_id['errors'])
        throttles = aggregate_sum(results_by_id['throttles'])
        duration_p50 = aggregate_percentile(results_by_id['duration_p50'])
        duration_p95 = aggregate_percentile(results_by_id['duration_p95'])
        duration_p99 = aggregate_percentile(results_by_id['duration_p99'])

        FunctionMetrics.new(
          function_name: function_name,
          period: @period,
          start_time: start_time,
          end_time: end_time,
          invocations: invocations,
          errors: errors,
          throttles: throttles,
          duration_p50: duration_p50,
          duration_p95: duration_p95,
          duration_p99: duration_p99
        )
      end

      def aggregate_sum(values)
        return 0 if values.nil? || values.empty?

        values.sum.to_i
      end

      def aggregate_percentile(values)
        return nil if values.nil? || values.empty?

        (values.sum.to_f / values.size).round(2)
      end
    end
  end
end
