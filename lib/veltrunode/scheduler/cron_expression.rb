# frozen_string_literal: true

require_relative 'base_expression'
require_relative 'cron_field'

module Veltrunode
  module Scheduler
    # AWS EventBridge Scheduler の cron(分 時 日 月 曜日 年) 式をパース・計算するクラス
    class CronExpression < BaseExpression
      CRON_PATTERN = /\A\s*cron\s*\(\s*(.+?)\s*\)\s*\z/

      attr_reader :minute_field, :hour_field, :day_of_month_field,
                  :month_field, :day_of_week_field, :year_field

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
        results = []
        last_found = from_time.to_time

        count.times do
          next_time = find_next(last_found, tz)
          break unless next_time

          results << next_time
          last_found = next_time
        end

        results
      end

      private

      def parse_and_validate!
        match = CRON_PATTERN.match(raw_expression)
        unless match
          raise ScheduleExpressionError.new(
            "Invalid cron expression '#{raw_expression}'",
            expression: raw_expression,
            reason: 'invalid_format'
          )
        end

        fields = match[1].split(/\s+/)
        unless fields.size == 6
          raise ScheduleExpressionError.new(
            "Cron expression must contain exactly 6 fields, got #{fields.size} in '#{raw_expression}'",
            expression: raw_expression,
            reason: 'invalid_field_count'
          )
        end

        min_str, hour_str, dom_str, month_str, dow_str, year_str = fields

        @minute_field       = CronField::NumericField.new(min_str, 0, 59, field_name: 'minute')
        @hour_field         = CronField::NumericField.new(hour_str, 0, 23, field_name: 'hour')
        @day_of_month_field = CronField::DayOfMonthField.new(dom_str)
        @month_field        = CronField::MonthField.new(month_str)
        @day_of_week_field  = CronField::DayOfWeekField.new(dow_str)
        @year_field         = CronField::NumericField.new(year_str, 1970, 2199, field_name: 'year')

        validate_day_fields!
      end

      def validate_day_fields!
        dom_q = @day_of_month_field.question_mark?
        dow_q = @day_of_week_field.question_mark?

        return if dom_q ^ dow_q

        msg = if dom_q && dow_q
                "Both day-of-month and day-of-week cannot be '?' in '#{raw_expression}'"
              else
                "One of day-of-month or day-of-week must be '?' in '#{raw_expression}'"
              end

        raise ScheduleExpressionError.new(
          msg,
          expression: raw_expression,
          reason: 'day_fields_question_mark_constraint'
        )
      end

      def find_next(origin_time, tz)
        origin_local = TimezoneHelper.time_in_zone(origin_time, tz)
        state = initial_search_state(origin_local)

        while state[:year] <= 2199
          unless step_year?(state)
            return nil unless state[:year]

            next
          end

          next unless step_month?(state)
          next unless step_day?(state)
          next unless step_hour?(state)
          next unless step_minute?(state)

          candidate = TimezoneHelper.local_to_time(
            state[:year], state[:month], state[:day],
            state[:hour], state[:min], 0, tz
          )
          return candidate if candidate > origin_time

          state[:min] += 1
        end

        nil
      end

      def initial_search_state(origin_local)
        {
          year: origin_local.year,
          month: origin_local.month,
          day: origin_local.day,
          hour: origin_local.hour,
          min: origin_local.min + 1
        }
      end

      def step_year?(state)
        return true if @year_field.match?(state[:year])

        state[:year] = @year_field.next_value(state[:year])
        reset_lower(state, :month)
        false
      end

      def step_month?(state)
        return true if @month_field.match?(state[:month])

        next_m = @month_field.next_value(state[:month])
        if next_m
          state[:month] = next_m
        else
          state[:year] += 1
          state[:month] = 1
        end
        reset_lower(state, :day)
        false
      end

      def step_day?(state)
        last_day = Date.new(state[:year], state[:month], -1).day
        if state[:day] > last_day
          state[:month] += 1
          reset_lower(state, :day)
          return false
        end

        return true if match_day?(state[:year], state[:month], state[:day])

        state[:day] += 1
        reset_lower(state, :hour)
        false
      end

      def step_hour?(state)
        return true if @hour_field.match?(state[:hour])

        next_h = @hour_field.next_value(state[:hour])
        if next_h
          state[:hour] = next_h
        else
          state[:day] += 1
          state[:hour] = 0
        end
        reset_lower(state, :min)
        false
      end

      def step_minute?(state)
        return true if @minute_field.match?(state[:min])

        next_min = @minute_field.next_value(state[:min])
        if next_min
          state[:min] = next_min
        else
          state[:hour] += 1
          state[:min] = 0
        end
        false
      end

      def reset_lower(state, level)
        case level
        when :month
          state[:month] = 1
          state[:day] = 1
          state[:hour] = 0
          state[:min] = 0
        when :day
          state[:day] = 1
          state[:hour] = 0
          state[:min] = 0
        when :hour
          state[:hour] = 0
          state[:min] = 0
        when :min
          state[:min] = 0
        end
      end

      def match_day?(year, month, day)
        @day_of_month_field.match?(year, month, day) &&
          @day_of_week_field.match?(year, month, day)
      end
    end
  end
end
