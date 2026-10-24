# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Model
    # Lambda 関数の CloudWatch メトリクスアラーム定義モデル
    class Alarm
      VALID_METRICS = %i[errors duration throttles error_rate].freeze
      PRESET_NAMES = %i[recommended].freeze
      DEFAULT_PERIOD = 60
      DEFAULT_EVALUATION_PERIODS = 1
      DEFAULT_COMPARISON_OPERATOR = 'GreaterThanOrEqualToThreshold'
      DEFAULT_TREAT_MISSING_DATA = 'notBreaching'

      METRIC_STATISTICS = {
        errors: 'Sum',
        duration: 'Average',
        throttles: 'Sum'
      }.freeze

      attr_reader :metric,
                  :threshold,
                  :evaluation_periods,
                  :period,
                  :statistic,
                  :comparison_operator,
                  :treat_missing_data,
                  :alarm_actions,
                  :ok_actions

      def initialize(
        metric:,
        threshold:,
        evaluation_periods: DEFAULT_EVALUATION_PERIODS,
        period: DEFAULT_PERIOD,
        statistic: nil,
        comparison_operator: DEFAULT_COMPARISON_OPERATOR,
        treat_missing_data: DEFAULT_TREAT_MISSING_DATA,
        alarm_actions: [],
        ok_actions: []
      )
        @metric = normalize_metric(metric)
        @threshold = normalize_threshold(threshold)
        @evaluation_periods = evaluation_periods.to_i
        @period = period.to_i
        stat_val = statistic || default_statistic_for(@metric)
        @statistic = stat_val&.to_s&.freeze
        @comparison_operator = comparison_operator.to_s.freeze
        @treat_missing_data = treat_missing_data.to_s.freeze
        @alarm_actions = freeze_actions(alarm_actions)
        @ok_actions = freeze_actions(ok_actions)

        validate!
        freeze
      end

      def error_rate?
        @metric == :error_rate
      end

      def validate!
        validate_metric!
        validate_threshold!
        validate_evaluation_periods!
        validate_period!
      end

      private

      def normalize_metric(m)
        m.to_s.downcase.to_sym
      end

      def normalize_threshold(val)
        raise ValidationError, "Threshold is required for alarm #{@metric}" if val.nil?

        num = Float(val)
        num.to_i == num ? num.to_i : num
      rescue ArgumentError, TypeError
        raise ValidationError, "Threshold must be numeric: #{val.inspect}"
      end

      def default_statistic_for(m)
        METRIC_STATISTICS[m] || 'Sum'
      end

      def freeze_actions(actions)
        list = actions.is_a?(Array) ? actions : [actions].compact
        list.map do |act|
          if act.is_a?(Hash)
            freeze_hash(act)
          elsif act.respond_to?(:name) || act.is_a?(Symbol)
            act
          else
            act.to_s.strip.freeze
          end
        end.freeze
      end

      def freeze_hash(hash)
        hash.each_with_object({}) do |(k, v), memo|
          frozen_val = v.is_a?(Hash) ? freeze_hash(v) : v.to_s.freeze
          memo[k.to_s.freeze] = frozen_val
        end.freeze
      end

      def validate_metric!
        return if VALID_METRICS.include?(@metric)

        raise ValidationError, "Unsupported alarm metric: #{@metric}. Valid metrics are #{VALID_METRICS.join(', ')}"
      end

      def validate_threshold!
        unless @threshold.is_a?(Numeric) && @threshold >= 0
          raise ValidationError, "Alarm threshold must be a non-negative number: #{@threshold.inspect}"
        end

        return unless @metric == :error_rate && @threshold > 100

        raise ValidationError, "Alarm error_rate threshold must be between 0 and 100: #{@threshold.inspect}"
      end

      def validate_evaluation_periods!
        return if @evaluation_periods.is_a?(Integer) && @evaluation_periods >= 1

        raise ValidationError, "Alarm evaluation_periods must be at least 1: #{@evaluation_periods.inspect}"
      end

      def validate_period!
        return if @period.is_a?(Integer) && @period >= 10 && (@period % 10).zero?

        raise ValidationError, "Alarm period must be a multiple of 10 seconds: #{@period.inspect}"
      end
    end
  end
end
