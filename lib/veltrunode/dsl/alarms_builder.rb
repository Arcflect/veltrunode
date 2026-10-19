# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/alarm'

module Veltrunode
  module DSL
    # Lambda 関数の alarms ブロック用 DSL ビルダー
    class AlarmsBuilder < BaseBuilder
      def initialize(default_topic: nil)
        super()
        @default_topic = default_topic
        @alarm_entries = []
      end

      # デフォルトの通知先 SNS トピックを設定
      def topic(t)
        @default_topic = t
      end

      # エラー数アラームの定義
      def errors(threshold_or_opts = 1, **)
        add_alarm(:errors, threshold_or_opts, **)
      end

      # 期間（レイテンシ）アラームの定義
      def duration(threshold_or_opts = 5000, **)
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
        @alarm_entries.map do |entry|
          actions = entry[:alarm_actions] || entry[:topic] || @default_topic
          action_list = actions ? Array(actions) : []

          Model::Alarm.new(
            metric: entry[:metric],
            threshold: entry[:threshold],
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

      def add_alarm(metric, threshold_or_opts, **kwargs)
        opts = if threshold_or_opts.is_a?(Hash)
                 threshold_or_opts.merge(kwargs)
               elsif threshold_or_opts.nil?
                 kwargs
               else
                 { threshold: threshold_or_opts }.merge(kwargs)
               end

        entry = opts.dup
        entry[:metric] = metric
        entry[:threshold] ||= default_threshold_for(metric)

        @alarm_entries << entry
      end

      def default_threshold_for(metric)
        case metric.to_sym
        when :duration
          5000
        else
          1
        end
      end
    end
  end
end
