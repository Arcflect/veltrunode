# frozen_string_literal: true

require 'date'
require_relative 'errors'

module Veltrunode
  module Scheduler
    # cron 式の個別フィールドを解析・判定するクラス群
    module CronField
      MONTH_NAMES = {
        'JAN' => 1, 'FEB' => 2, 'MAR' => 3, 'APR' => 4,
        'MAY' => 5, 'JUN' => 6, 'JUL' => 7, 'AUG' => 8,
        'SEP' => 9, 'OCT' => 10, 'NOV' => 11, 'DEC' => 12
      }.freeze

      # AWS EventBridge: 1=SUN, 2=MON, ..., 7=SAT
      DAY_NAMES = {
        'SUN' => 1, 'MON' => 2, 'TUE' => 3, 'WED' => 4,
        'THU' => 5, 'FRI' => 6, 'SAT' => 7
      }.freeze

      # 基本的な数値フィールド（分、時、年、単純な月）
      class NumericField
        attr_reader :raw, :min_val, :max_val, :field_name

        def initialize(raw, min_val, max_val, field_name:)
          @raw = raw.to_s.strip.upcase
          @min_val = min_val
          @max_val = max_val
          @field_name = field_name
          @values = parse_values
        end

        def match?(val)
          @values.include?(val)
        end

        def next_value(from_val)
          @values.select { |v| v >= from_val }.min
        end

        def min_matching
          @values.min
        end

        private

        def parse_values
          res = Set.new
          parts = @raw.split(',')

          parts.each do |part|
            part = part.strip
            if part == '*'
              (min_val..max_val).each { |v| res.add(v) }
            elsif part.include?('/')
              sub_parts = part.split('/')
              raise invalid_field_error(part) unless sub_parts.size == 2

              start_str, step_str = sub_parts
              start_val = start_str == '*' ? min_val : parse_single(start_str)
              step_val = parse_int(step_str)
              raise invalid_field_error(part, 'step must be positive') if step_val <= 0

              v = start_val
              while v <= max_val
                res.add(v)
                v += step_val
              end
            elsif part.include?('-')
              sub_parts = part.split('-')
              raise invalid_field_error(part) unless sub_parts.size == 2

              start_val = parse_single(sub_parts[0])
              end_val = parse_single(sub_parts[1])
              raise invalid_field_error(part, 'range start must be <= end') if start_val > end_val

              (start_val..end_val).each { |v| res.add(v) }
            else
              res.add(parse_single(part))
            end
          end

          raise invalid_field_error(@raw, 'no valid values resolved') if res.empty?

          res
        end

        def parse_single(str)
          val = parse_int(str)
          unless (min_val..max_val).cover?(val)
            raise invalid_field_error(str, "value must be between #{min_val} and #{max_val}")
          end

          val
        end

        def parse_int(str)
          raise invalid_field_error(str) unless /\A\d+\z/.match?(str)

          str.to_i
        end

        def invalid_field_error(token, detail = nil)
          msg = "Invalid #{field_name} field '#{@raw}' (token: '#{token}')"
          msg += ": #{detail}" if detail
          ScheduleExpressionError.new(msg, expression: @raw, reason: "invalid_#{field_name}_field")
        end
      end

      # 月フィールド (1-12, JAN-DEC)
      class MonthField < NumericField
        def initialize(raw)
          super(raw, 1, 12, field_name: 'month')
        end

        private

        def parse_single(str)
          normalized = str.upcase
          if MONTH_NAMES.key?(normalized)
            MONTH_NAMES[normalized]
          else
            super
          end
        end
      end

      # 日フィールド (Day of Month: 1-31, ?, *, L, LW, dW)
      class DayOfMonthField
        attr_reader :raw

        def initialize(raw)
          @raw = raw.to_s.strip.upcase
          validate!
        end

        def question_mark?
          @raw == '?'
        end

        def match?(year, month, day)
          return true if question_mark? || @raw == '*'

          last_day = Date.new(year, month, -1).day

          if @raw == 'L'
            day == last_day
          elsif @raw == 'LW'
            day == last_weekday_of_month(year, month, last_day)
          elsif @raw.end_with?('W')
            target = @raw.chomp('W').to_i
            day == nearest_weekday(year, month, target, last_day)
          else
            @numeric_field ||= NumericField.new(@raw, 1, 31, field_name: 'day-of-month')
            @numeric_field.match?(day)
          end
        end

        private

        def validate!
          return if %w[? * L LW].include?(@raw)

          if @raw.end_with?('W')
            target = @raw.chomp('W')
            unless /\A\d+\z/.match?(target) && (1..31).cover?(target.to_i)
              raise ScheduleExpressionError.new(
                "Invalid W expression in day-of-month '#{@raw}'",
                expression: @raw,
                reason: 'invalid_day_of_month_field'
              )
            end
            return
          end

          # 単純な数値リスト/範囲/ステップのバリデーション
          NumericField.new(@raw, 1, 31, field_name: 'day-of-month')
        end

        def last_weekday_of_month(year, month, last_day)
          d = last_day
          while d >= 1
            date = Date.new(year, month, d)
            return d if date.wday.between?(1, 5) # 月〜金

            d -= 1
          end
        end

        def nearest_weekday(year, month, target_day, last_day)
          target_day = target_day.clamp(1, last_day)
          date = Date.new(year, month, target_day)

          case date.wday
          when 1..5 # 平日
            target_day
          when 6 # 土曜
            if target_day == 1
              # 1日が土曜の場合、月またぎせず翌週月曜 (3日)
              3
            else
              # 前日金曜
              target_day - 1
            end
          when 0 # 日曜
            if target_day == last_day
              # 月末が日曜の場合、前週金曜
              target_day - 2
            else
              # 翌日月曜
              target_day + 1
            end
          end
        end
      end

      # 曜日フィールド (Day of Week: 1-7 or SUN-SAT, ?, *, L, dL, d#n)
      class DayOfWeekField
        attr_reader :raw

        def initialize(raw)
          @raw = raw.to_s.strip.upcase
          validate!
        end

        def question_mark?
          @raw == '?'
        end

        def match?(year, month, day)
          return true if question_mark? || @raw == '*'

          date = Date.new(year, month, day)
          # EventBridge: 1=SUN, 2=MON, ..., 7=SAT
          current_eb_wday = date.wday + 1

          if @raw == 'L'
            # L 単体は 7 (SAT)
            current_eb_wday == 7
          elsif @raw.end_with?('L')
            target_eb_wday = parse_wday_token(@raw.chomp('L'))
            day == last_day_of_eb_wday_in_month(year, month, target_eb_wday)
          elsif @raw.include?('#')
            parts = @raw.split('#')
            target_eb_wday = parse_wday_token(parts[0])
            nth = parts[1].to_i
            day == nth_day_of_eb_wday_in_month(year, month, target_eb_wday, nth)
          else
            numeric_field.match?(current_eb_wday)
          end
        end

        private

        def numeric_field
          @numeric_field ||= begin
            normalized_raw = normalize_day_names(@raw)
            NumericField.new(normalized_raw, 1, 7, field_name: 'day-of-week')
          end
        end

        def validate!
          return if %w[? * L].include?(@raw)

          if @raw.end_with?('L')
            token = @raw.chomp('L')
            parse_wday_token(token)
            return
          end

          if @raw.include?('#')
            parts = @raw.split('#')
            unless parts.size == 2 && (1..5).cover?(parts[1].to_i)
              raise ScheduleExpressionError.new(
                "Invalid # expression in day-of-week '#{@raw}'",
                expression: @raw,
                reason: 'invalid_day_of_week_field'
              )
            end
            parse_wday_token(parts[0])
            return
          end

          normalized_raw = normalize_day_names(@raw)
          NumericField.new(normalized_raw, 1, 7, field_name: 'day-of-week')
        end

        def normalize_day_names(str)
          DAY_NAMES.reduce(str) do |acc, (name, num)|
            acc.gsub(name, num.to_s)
          end
        end

        def parse_wday_token(token)
          token = token.upcase
          return DAY_NAMES[token] if DAY_NAMES.key?(token)

          val = token.to_i
          if (1..7).cover?(val) && val.to_s == token
            val
          else
            raise ScheduleExpressionError.new(
              "Invalid day of week token '#{token}' in '#{@raw}'",
              expression: @raw,
              reason: 'invalid_day_of_week_field'
            )
          end
        end

        def last_day_of_eb_wday_in_month(year, month, target_eb_wday)
          last_day = Date.new(year, month, -1).day
          d = last_day
          while d >= 1
            return d if (Date.new(year, month, d).wday + 1) == target_eb_wday

            d -= 1
          end
          nil
        end

        def nth_day_of_eb_wday_in_month(year, month, target_eb_wday, nth)
          count = 0
          last_day = Date.new(year, month, -1).day
          (1..last_day).each do |d|
            if (Date.new(year, month, d).wday + 1) == target_eb_wday
              count += 1
              return d if count == nth
            end
          end
          nil
        end
      end
    end
  end
end
