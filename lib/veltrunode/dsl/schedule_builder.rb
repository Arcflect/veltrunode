# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/schedule'

module Veltrunode
  module DSL
    class ScheduleBuilder < BaseBuilder
      def initialize(name)
        super()
        @name = name.to_s
        @target_function = nil
        @expression_type = nil
        @expression = nil
        @timezone = 'UTC'
        @state = :enabled
        @flexible_window = { mode: :off }
        @input = nil
        @retry_policy = nil
        @dlq = nil
        @execution_role = nil
      end

      def target(fn_name)
        @target_function = fn_name.to_s
      end

      def target_function(fn_name)
        target(fn_name)
      end

      def cron(expr, timezone: nil)
        @expression_type = :cron
        @expression = expr.to_s
        @timezone = timezone.to_s if timezone
      end

      def rate(expr, timezone: nil)
        @expression_type = :rate
        @expression = expr.to_s.start_with?('rate(') ? expr.to_s : "rate(#{expr})"
        @timezone = timezone.to_s if timezone
      end

      def at(expr, timezone: nil)
        @expression_type = :at
        @expression = expr.to_s
        @timezone = timezone.to_s if timezone
      end

      def timezone(tz)
        @timezone = tz.to_s
      end

      def state(st)
        @state = st.to_sym
      end

      def flexible_window(hash)
        @flexible_window = hash
      end

      def input(data)
        @input = data
      end

      def retry(maximum_attempts: nil, maximum_event_age: nil)
        @retry_policy = {
          maximum_attempts: maximum_attempts,
          maximum_event_age_in_seconds: maximum_event_age
        }.compact
      end

      def retry_policy(hash)
        @retry_policy = hash
      end

      def dead_letter_queue(arn: nil)
        @dlq = arn.to_s if arn
      end

      def dlq(arn)
        @dlq = arn.to_s
      end

      def execution_role(role)
        @execution_role = role.to_s
      end

      def build
        Model::Schedule.new(
          name: @name,
          target_function: @target_function,
          expression_type: @expression_type,
          expression: @expression,
          timezone: @timezone,
          state: @state,
          flexible_window: @flexible_window,
          input: @input,
          retry_policy: @retry_policy,
          dlq: @dlq,
          execution_role: @execution_role
        )
      end
    end
  end
end
