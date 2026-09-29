# frozen_string_literal: true

require_relative 'base_expression'

module Veltrunode
  module Scheduler
    # AWS EventBridge Scheduler の rate(value unit) 式をパース・計算するクラス
    class RateExpression < BaseExpression
      RATE_PATTERN = /\A\s*rate\s*\(\s*(\d+)\s+([a-zA-Z]+)\s*\)\s*\z/

      UNITS = {
        'minute' => { singular: true, seconds: 60 },
        'minutes' => { singular: false, seconds: 60 },
        'hour' => { singular: true, seconds: 3600 },
        'hours' => { singular: false, seconds: 3600 },
        'day' => { singular: true, seconds: 86_400 },
        'days' => { singular: false, seconds: 86_400 }
      }.freeze

      attr_reader :value, :unit, :interval_seconds

      def initialize(raw_expression)
        super
        parse_and_validate!
      end

      # 基準日時から次回以降の実行予定日時を N 回分計算して返します
      #
      # @param count [Integer] 取得する次回実行時刻の回数
      # @param from_time [Time] 基準日時（未指定時は現在時刻）
      # @param timezone [String] IANA タイムゾーン識別子 (デフォルト: 'UTC')
      # @return [Array<Time>]
      def next_occurrences(count = 5, from_time: Time.now, timezone: 'UTC')
        return [] if count <= 0

        tz = TimezoneHelper.resolve_timezone(timezone)
        base = from_time.to_time

        (1..count).map do |i|
          occurrence = base + (i * interval_seconds)
          TimezoneHelper.time_in_zone(occurrence, tz)
        end
      end

      private

      def parse_and_validate!
        match = RATE_PATTERN.match(raw_expression)
        unless match
          raise ScheduleExpressionError.new(
            "Invalid rate expression '#{raw_expression}'",
            expression: raw_expression,
            reason: 'invalid_format'
          )
        end

        val = match[1].to_i
        unit_str = match[2].downcase

        if val <= 0
          raise ScheduleExpressionError.new(
            "Rate expression value must be greater than zero in '#{raw_expression}'",
            expression: raw_expression,
            reason: 'value_must_be_greater_than_zero'
          )
        end

        unit_info = UNITS[unit_str]
        unless unit_info
          raise ScheduleExpressionError.new(
            "Unknown unit '#{unit_str}' in '#{raw_expression}'. Expected minute(s), hour(s), or day(s).",
            expression: raw_expression,
            reason: 'unknown_unit'
          )
        end

        # 単数・複数の厳格チェック
        if val == 1 && !unit_info[:singular]
          raise ScheduleExpressionError.new(
            "Singular unit expected for value 1 in '#{raw_expression}'. Did you mean 'rate(1 #{unit_str.chomp('s')})'?",
            expression: raw_expression,
            reason: 'singular_unit_expected'
          )
        elsif val > 1 && unit_info[:singular]
          raise ScheduleExpressionError.new(
            "Plural unit expected for value #{val} in '#{raw_expression}'. Did you mean 'rate(#{val} #{unit_str}s)'?",
            expression: raw_expression,
            reason: 'plural_unit_expected'
          )
        end

        @value = val
        @unit = unit_str
        @interval_seconds = val * unit_info[:seconds]
      end
    end
  end
end
