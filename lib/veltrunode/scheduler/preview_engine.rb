# frozen_string_literal: true

require 'time'
require_relative 'parser'
require_relative 'timezone_helper'

module Veltrunode
  module Scheduler
    # DST（夏時間）遷移情報を保持する値オブジェクト
    class DstTransition
      attr_reader :sequence,
                  :transition_time,
                  :type,
                  :from_abbr,
                  :to_abbr,
                  :from_offset,
                  :to_offset,
                  :description

      def initialize(
        sequence:,
        transition_time:,
        type:,
        from_abbr:,
        to_abbr:,
        from_offset:,
        to_offset:,
        description:
      )
        @sequence = sequence
        @transition_time = transition_time
        @type = type
        @from_abbr = from_abbr
        @to_abbr = to_abbr
        @from_offset = from_offset
        @to_offset = to_offset
        @description = description
        freeze
      end

      def to_h
        {
          'sequence' => sequence,
          'type' => type.to_s,
          'from_timezone_abbr' => from_abbr,
          'to_timezone_abbr' => to_abbr,
          'from_offset' => from_offset,
          'to_offset' => to_offset,
          'description' => description
        }
      end
    end

    # 1回分の実行予定日時情報を保持する値オブジェクト
    class PreviewOccurrence
      attr_reader :sequence,
                  :time,
                  :local_time,
                  :utc_time,
                  :timezone,
                  :timezone_abbr,
                  :utc_offset,
                  :dst,
                  :dst_transition,
                  :shift_notice

      def initialize(
        sequence:,
        time:,
        local_time:,
        utc_time:,
        timezone:,
        timezone_abbr:,
        utc_offset:,
        dst:,
        dst_transition: nil,
        shift_notice: nil
      )
        @sequence = sequence
        @time = time
        @local_time = local_time
        @utc_time = utc_time
        @timezone = timezone
        @timezone_abbr = timezone_abbr
        @utc_offset = utc_offset
        @dst = dst
        @dst_transition = dst_transition
        @shift_notice = shift_notice
        freeze
      end

      def dst?
        @dst == true
      end

      def local_iso8601
        local_time.strftime('%Y-%m-%dT%H:%M:%S') + utc_offset
      end

      def utc_iso8601
        utc_time.strftime('%Y-%m-%dT%H:%M:%SZ')
      end

      def local_display
        "#{local_time.strftime('%Y-%m-%d %H:%M:%S')} #{utc_offset} (#{timezone_abbr})"
      end

      def utc_display
        "#{utc_time.strftime('%Y-%m-%d %H:%M:%S')} UTC"
      end

      def to_h
        {
          'sequence' => sequence,
          'local_time' => local_iso8601,
          'utc_time' => utc_iso8601,
          'timezone' => timezone,
          'timezone_abbr' => timezone_abbr,
          'utc_offset' => utc_offset,
          'dst' => dst,
          'dst_transition' => dst_transition&.to_h,
          'shift_notice' => shift_notice
        }
      end
    end

    # プレビュー結果全体を保持する値オブジェクト
    class PreviewResult
      DEFAULT_DISCLAIMER = 'This preview is an estimate for reference only. ' \
                           'Final execution schedule is determined and executed by AWS EventBridge Scheduler.'

      attr_reader :schedule_name,
                  :target_function,
                  :expression,
                  :expression_type,
                  :timezone,
                  :count,
                  :from_time,
                  :occurrences,
                  :dst_transitions,
                  :disclaimer

      def initialize(
        schedule_name:,
        target_function:,
        expression:,
        expression_type:,
        timezone:,
        count:,
        from_time:,
        occurrences:,
        dst_transitions:,
        disclaimer: DEFAULT_DISCLAIMER
      )
        @schedule_name = schedule_name
        @target_function = target_function
        @expression = expression
        @expression_type = expression_type
        @timezone = timezone
        @count = count
        @from_time = from_time
        @occurrences = occurrences.freeze
        @dst_transitions = dst_transitions.freeze
        @disclaimer = disclaimer
        freeze
      end

      def to_h
        {
          'schedule_name' => schedule_name,
          'target_function' => target_function,
          'expression' => expression,
          'expression_type' => expression_type.to_s,
          'timezone' => timezone,
          'count' => count,
          'from_time' => from_time.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
          'occurrences' => occurrences.map(&:to_h),
          'dst_transitions' => dst_transitions.map(&:to_h),
          'disclaimer' => disclaimer
        }
      end
    end

    # スケジュール実行予定日時プレビュー計算エンジン
    class PreviewEngine
      class << self
        # 将来の実行予定日時を計算し、DST遷移情報を含むプレビュー結果を生成します
        #
        # @param schedule [Veltrunode::Model::Schedule, Hash] スケジュールモデルまたは設定ハッシュ
        # @param count [Integer] 計算する実行回数（デフォルト: 10）
        # @param from_time [Time] 基準日時（デフォルト: Time.now）
        # @return [PreviewResult]
        def preview(schedule, count: 10, from_time: Time.now)
          schedule_name = extract_schedule_name(schedule)
          target_func = extract_target_function(schedule)
          raw_expr = extract_expression(schedule)
          tz_name = extract_timezone(schedule)

          expression_obj = Parser.parse(raw_expr)
          expression_type = detect_expression_type(expression_obj, schedule)

          occurrences_times = expression_obj.next_occurrences(
            count,
            from_time: from_time,
            timezone: tz_name
          )

          build_preview_result(
            schedule_name: schedule_name,
            target_function: target_func,
            expression: raw_expr,
            expression_obj: expression_obj,
            expression_type: expression_type,
            timezone_name: tz_name,
            count: count,
            from_time: from_time,
            occurrences_times: occurrences_times
          )
        end

        private

        def extract_schedule_name(schedule)
          if schedule.respond_to?(:name)
            schedule.name
          elsif schedule.is_a?(Hash)
            schedule[:name] || schedule['name'] || 'default'
          else
            'default'
          end
        end

        def extract_target_function(schedule)
          if schedule.respond_to?(:target_function)
            schedule.target_function
          elsif schedule.is_a?(Hash)
            schedule[:target_function] || schedule['target_function']
          end
        end

        def extract_expression(schedule)
          if schedule.respond_to?(:expression)
            schedule.expression
          elsif schedule.is_a?(Hash)
            schedule[:expression] || schedule['expression']
          else
            schedule.to_s
          end
        end

        def extract_timezone(schedule)
          if schedule.respond_to?(:timezone)
            schedule.timezone
          elsif schedule.is_a?(Hash)
            schedule[:timezone] || schedule['timezone'] || 'UTC'
          else
            'UTC'
          end
        end

        def detect_expression_type(expression_obj, schedule)
          if schedule.respond_to?(:expression_type) && schedule.expression_type
            schedule.expression_type.to_s.to_sym
          elsif expression_obj.is_a?(CronExpression)
            :cron
          elsif expression_obj.is_a?(RateExpression)
            :rate
          elsif expression_obj.is_a?(AtExpression)
            :at
          else
            :unknown
          end
        end

        def build_preview_result(
          schedule_name:,
          target_function:,
          expression:,
          expression_obj:,
          expression_type:,
          timezone_name:,
          count:,
          from_time:,
          occurrences_times:
        )
          tz = TimezoneHelper.resolve_timezone(timezone_name)
          occurrences = []
          dst_transitions = []

          prev_period = initial_period(from_time, tz)

          occurrences_times.each_with_index do |time, index|
            sequence = index + 1
            utc_time = time.utc
            local_time = tz.respond_to?(:to_local) ? tz.to_local(time) : time
            period = current_period_for(utc_time, local_time, tz)

            abbr = period[:abbr]
            is_dst = period[:dst]
            offset_sec = period[:offset_sec]
            offset_str = format_offset(offset_sec)

            dst_trans = detect_dst_transition(sequence, utc_time, period, prev_period)
            dst_transitions << dst_trans if dst_trans

            shift_notice = detect_shift_notice(expression_obj, local_time, is_dst)

            occurrences << PreviewOccurrence.new(
              sequence: sequence,
              time: time,
              local_time: local_time,
              utc_time: utc_time,
              timezone: timezone_name,
              timezone_abbr: abbr,
              utc_offset: offset_str,
              dst: is_dst,
              dst_transition: dst_trans,
              shift_notice: shift_notice
            )

            prev_period = period
          end

          PreviewResult.new(
            schedule_name: schedule_name,
            target_function: target_function,
            expression: expression,
            expression_type: expression_type,
            timezone: timezone_name,
            count: count,
            from_time: from_time,
            occurrences: occurrences,
            dst_transitions: dst_transitions
          )
        end

        def initial_period(from_time, tz)
          utc_time = from_time.utc
          local_time = tz.respond_to?(:to_local) ? tz.to_local(from_time) : from_time
          current_period_for(utc_time, local_time, tz)
        end

        def current_period_for(utc_time, local_time, tz)
          if tz.respond_to?(:period_for_utc)
            begin
              p = tz.period_for_utc(utc_time)
              return {
                abbr: p.abbreviation.to_s,
                dst: p.dst?,
                offset_sec: p.utc_total_offset
              }
            rescue StandardError
              # fallback to local_time attributes below
            end
          end

          {
            abbr: local_time.strftime('%Z'),
            dst: local_time.dst?,
            offset_sec: local_time.utc_offset
          }
        end

        def detect_dst_transition(sequence, time, current, previous)
          return nil unless previous
          return nil if previous[:dst] == current[:dst] && previous[:offset_sec] == current[:offset_sec]

          type = current[:dst] && !previous[:dst] ? :spring_forward : :fall_back
          from_abbr = previous[:abbr]
          to_abbr = current[:abbr]
          from_offset = format_offset(previous[:offset_sec])
          to_offset = format_offset(current[:offset_sec])

          desc = if type == :spring_forward
                   "Daylight Saving Time begins: clocks advanced from #{from_abbr} (#{from_offset}) " \
                     "to #{to_abbr} (#{to_offset})."
                 else
                   "Daylight Saving Time ends: clocks shifted back from #{from_abbr} (#{from_offset}) " \
                     "to #{to_abbr} (#{to_offset})."
                 end

          DstTransition.new(
            sequence: sequence,
            transition_time: time,
            type: type,
            from_abbr: from_abbr,
            to_abbr: to_abbr,
            from_offset: from_offset,
            to_offset: to_offset,
            description: desc
          )
        end

        def detect_shift_notice(expression_obj, local_time, is_dst)
          return nil unless is_dst
          return nil unless expression_obj.is_a?(CronExpression)

          # cron の hour_field が指定されており、実際のローカル時間がその hour_field にマッチしない場合は
          # Spring Forward のギャップスキップによりシフトされたと判定できる
          hour_field = expression_obj.hour_field
          return nil if hour_field.nil? || hour_field.match?(local_time.hour)

          "Scheduled hour was skipped due to DST spring forward; executed at #{local_time.strftime('%H:%M:%S')}."
        end

        def format_offset(seconds)
          sec = seconds.to_i
          sign = sec.negative? ? '-' : '+'
          total_minutes = sec.abs / 60
          hours = total_minutes / 60
          minutes = total_minutes % 60
          format('%<sign>s%<hours>02d:%<minutes>02d', sign: sign, hours: hours, minutes: minutes)
        end
      end
    end
  end
end
