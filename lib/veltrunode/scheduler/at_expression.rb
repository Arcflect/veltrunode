# frozen_string_literal: true

require 'time'
require_relative 'base_expression'

module Veltrunode
  module Scheduler
    # AWS EventBridge Scheduler の at(yyyy-mm-ddThh:mm:ss) 式をパース・計算するクラス
    class AtExpression < BaseExpression
      AT_PATTERN = /\A\s*at\s*\(\s*([^()]+)\s*\)\s*\z/

      # ISO 8601: YYYY-MM-DDTHH:MM:SS (オプションで秒未満、オフセット Z または ±HH:MM)
      ISO8601_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?\z/i

      attr_reader :datetime_string, :year, :month, :day, :hour, :min, :sec, :has_offset

      def initialize(raw_expression)
        super
        parse_and_validate!
      end

      # 基準日時から次回以降の実行予定日時を返します（一回限りのため最大1件）
      #
      # @param count [Integer] 取得する次回実行時刻の回数
      # @param from_time [Time] 基準日時（未指定時は現在時刻）
      # @param timezone [String] IANA タイムゾーン識別子 (デフォルト: 'UTC')
      # @return [Array<Time>]
      def next_occurrences(count = 5, from_time: Time.now, timezone: 'UTC')
        return [] if count <= 0

        target_time = scheduled_time_in_zone(timezone)
        return [] if target_time <= from_time.to_time

        [target_time]
      end

      # 指定タイムゾーンにおける予定日時を取得します
      #
      # @param timezone [String]
      # @return [Time]
      def scheduled_time_in_zone(timezone = 'UTC')
        tz = TimezoneHelper.resolve_timezone(timezone)

        if has_offset
          parsed = Time.iso8601(datetime_string)
          TimezoneHelper.time_in_zone(parsed, tz)
        else
          TimezoneHelper.local_to_time(year, month, day, hour, min, sec, tz)
        end
      end

      private

      def parse_and_validate!
        match = AT_PATTERN.match(raw_expression)
        unless match
          raise ScheduleExpressionError.new(
            "Invalid at expression '#{raw_expression}'",
            expression: raw_expression,
            reason: 'invalid_format'
          )
        end

        dt_str = match[1].strip
        iso_match = ISO8601_PATTERN.match(dt_str)
        unless iso_match
          raise ScheduleExpressionError.new(
            "Invalid ISO 8601 datetime format '#{dt_str}' in '#{raw_expression}'",
            expression: raw_expression,
            reason: 'invalid_datetime_format'
          )
        end

        @datetime_string = dt_str
        @year = iso_match[1].to_i
        @month = iso_match[2].to_i
        @day = iso_match[3].to_i
        @hour = iso_match[4].to_i
        @min = iso_match[5].to_i
        @sec = iso_match[6].to_i
        offset_part = iso_match[7]
        @has_offset = !offset_part.nil?

        # 日付の妥当性確認 (例: 2月30日など)
        begin
          if @has_offset
            Time.iso8601(dt_str)
          else
            Date.new(@year, @month, @day)
            raise ArgumentError, 'hour out of range' unless (0..23).cover?(@hour)
            raise ArgumentError, 'minute out of range' unless (0..59).cover?(@min)
            raise ArgumentError, 'second out of range' unless (0..59).cover?(@sec)
          end
        rescue ArgumentError => e
          raise ScheduleExpressionError.new(
            "Invalid date or time value in '#{raw_expression}': #{e.message}",
            expression: raw_expression,
            reason: 'invalid_datetime_values'
          )
        end
      end
    end
  end
end
