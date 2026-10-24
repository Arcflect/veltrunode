# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/alarm'
require_relative '../validation'
require_relative '../diagnostics/diagnostic'

module Veltrunode
  module DSL
    # Lambda 関数の alarms ブロック用 DSL ビルダー
    class AlarmsBuilder < BaseBuilder
      attr_accessor :function_timeout

      def initialize(default_topic: nil, function_timeout: 3)
        super()
        @default_topic = default_topic
        @function_timeout = function_timeout
        @alarms_by_metric = {}
      end

      # デフォルトの通知先 SNS トピックを設定
      def topic(t)
        @default_topic = t
      end

      # プリセットを適用
      def preset(name = :recommended, **overrides)
        sym_name = name.to_sym
        unless Model::Alarm::PRESET_NAMES.include?(sym_name)
          diagnostic = Diagnostics::Diagnostic.new(
            code: 'VLT-ALARM-002',
            severity: :error,
            summary: "Unknown alarm preset '#{name}'. Supported presets: #{Model::Alarm::PRESET_NAMES.join(', ')}",
            suggested_action: 'Specify a valid alarm preset such as :recommended.',
            evidence: { 'preset' => name.to_s }
          )
          raise ValidationError.new("Unknown alarm preset '#{name}' (VLT-ALARM-002)", diagnostics: [diagnostic])
        end

        case sym_name
        when :recommended
          apply_recommended_preset
        end

        overrides.each do |k, v|
          send(k, v) if respond_to?(k)
        end
      end

      # エラー率アラームの定義
      def error_rate(threshold_or_opts = 1, **)
        add_alarm(:error_rate, threshold_or_opts, **)
      end

      # エラー数アラームの定義
      def errors(threshold_or_opts = 1, **)
        add_alarm(:errors, threshold_or_opts, **)
      end

      # 期間（レイテンシ）アラームの定義
      def duration(threshold_or_opts = nil, **)
        add_alarm(:duration, threshold_or_opts, **)
      end

      # スロットル数アラームの定義
      def throttles(threshold_or_opts = 1, **)
        add_alarm(:throttles, threshold_or_opts, **)
      end

      # 汎用アラーム定義
      def alarm(metric, threshold_or_opts = nil, **)
        add_alarm(metric, threshold_or_opts, **)
      end

      def build
        @alarms_by_metric.values.map do |entry|
          actions = entry[:alarm_actions] || entry[:topic] || @default_topic
          action_list = actions ? Array(actions) : []

          threshold = entry[:threshold]
          threshold = recommended_duration_threshold if entry[:metric] == :duration && entry[:preset_calculated]

          Model::Alarm.new(
            metric: entry[:metric],
            threshold: threshold,
            evaluation_periods: entry[:evaluation_periods] || Model::Alarm::DEFAULT_EVALUATION_PERIODS,
            period: entry[:period] || Model::Alarm::DEFAULT_PERIOD,
            statistic: entry[:statistic],
            comparison_operator: entry[:comparison_operator] || Model::Alarm::DEFAULT_COMPARISON_OPERATOR,
            treat_missing_data: entry[:treat_missing_data] || Model::Alarm::DEFAULT_TREAT_MISSING_DATA,
            alarm_actions: action_list,
            ok_actions: entry[:ok_actions] || []
          )
        end
      end

      private

      def apply_recommended_preset
        add_alarm(:error_rate, threshold: 1, comparison_operator: 'GreaterThanThreshold')
        add_alarm(:throttles, threshold: 1, comparison_operator: 'GreaterThanOrEqualToThreshold')
        add_alarm(:duration, threshold: recommended_duration_threshold,
                             comparison_operator: 'GreaterThanThreshold',
                             preset_calculated: true)
      end

      def recommended_duration_threshold
        ((@function_timeout || 3).to_f * 1000 * 0.8).to_i
      end

      def add_alarm(metric, threshold_or_opts = nil, **kwargs)
        opts = if threshold_or_opts.is_a?(Hash)
                 threshold_or_opts.merge(kwargs)
               elsif threshold_or_opts.nil?
                 kwargs
               else
                 { threshold: threshold_or_opts }.merge(kwargs)
               end

        metric_sym = metric.to_sym
        existing = @alarms_by_metric[metric_sym] || {}

        entry = existing.merge(opts)
        entry[:metric] = metric_sym
        entry.delete(:preset_calculated) if opts.key?(:threshold) && !opts.key?(:preset_calculated)
        entry[:threshold] ||= default_threshold_for(metric_sym)

        @alarms_by_metric[metric_sym] = entry
      end

      def default_threshold_for(metric)
        case metric.to_sym
        when :duration
          recommended_duration_threshold
        else
          1
        end
      end
    end
  end
end
