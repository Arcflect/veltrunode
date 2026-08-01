# frozen_string_literal: true

require 'time'

module Veltrunode
  module Model
    class Schedule
      EXPRESSION_TYPES = %i[cron rate at].freeze
      STATES = %i[enabled disabled].freeze
      RATE_UNIT_PATTERN = /\Arate\(\s*(?:1\s+(?:minute|hour|day)|[2-9]\d*\s+(?:minutes|hours|days))\s*\)\z/i
      IANA_TIMEZONE_PATTERN = %r{\A(?:UTC|GMT|[A-Za-z0-9_\-+]+(?:/[A-Za-z0-9_\-+]+)+)\z}

      attr_reader :name,
                  :target_function,
                  :expression_type,
                  :expression,
                  :timezone,
                  :state,
                  :flexible_window,
                  :input,
                  :retry_policy,
                  :dlq,
                  :execution_role

      def initialize(
        name:,
        target_function:,
        expression_type:,
        expression:,
        timezone: 'UTC',
        state: :enabled,
        flexible_window: { mode: :off },
        input: nil,
        retry_policy: nil,
        dlq: nil,
        execution_role: nil
      )
        exp_type = expression_type.to_s.to_sym
        st = state.to_s.to_sym

        validate!(
          name:,
          target_function:,
          expression_type: exp_type,
          expression:,
          timezone:,
          state: st,
          retry_policy:
        )

        @name = name.to_s.freeze
        @target_function = target_function.to_s.freeze
        @expression_type = exp_type
        @expression = expression.to_s.strip.freeze
        @timezone = timezone.to_s.strip.freeze
        @state = st
        @flexible_window = freeze_value(flexible_window)
        @input = freeze_value(input)
        @retry_policy = freeze_value(retry_policy)
        @dlq = freeze_value(dlq)
        @execution_role = freeze_value(execution_role)

        freeze
      end

      private

      def validate!(name:, target_function:, expression_type:, expression:, timezone:, state:, retry_policy:)
        raise ValidationError, 'Schedule name is required' if blank?(name)
        raise ValidationError, 'Schedule target_function is required' if blank?(target_function)

        unless EXPRESSION_TYPES.include?(expression_type)
          raise ValidationError,
                "Invalid expression_type '#{expression_type}'. Must be one of: #{EXPRESSION_TYPES.join(', ')}"
        end

        unless STATES.include?(state)
          raise ValidationError, "Invalid state '#{state}'. Must be one of: #{STATES.join(', ')}"
        end

        validate_expression!(expression_type, expression)
        validate_timezone!(timezone)
        validate_retry_policy!(retry_policy)
      end

      def validate_expression!(type, expr)
        raise ValidationError, 'Schedule expression is required' if blank?(expr)

        expr_str = expr.to_s.strip

        case type
        when :cron
          validate_cron_expression!(expr_str)
        when :rate
          validate_rate_expression!(expr_str)
        when :at
          validate_at_expression!(expr_str)
        end
      end

      def validate_cron_expression!(expr)
        inner = if expr.start_with?('cron(') && expr.end_with?(')')
                  expr[5..-2].strip
                else
                  expr
                end

        fields = inner.split(/\s+/)
        return if fields.size == 6

        raise ValidationError,
              "Invalid cron expression '#{expr}'. AWS cron expressions must contain exactly 6 fields."
      end

      def validate_rate_expression!(expr)
        return if RATE_UNIT_PATTERN.match?(expr)

        raise ValidationError,
              "Invalid rate expression '#{expr}'. Must be in format 'rate(N unit)' (e.g. rate(5 minutes))."
      end

      def validate_at_expression!(expr)
        inner = if expr.start_with?('at(') && expr.end_with?(')')
                  expr[3..-2].strip
                else
                  expr
                end

        begin
          Time.iso8601(inner)
        rescue ArgumentError
          raise ValidationError,
                "Invalid at expression '#{expr}'. Must be a valid ISO 8601 date-time format."
        end
      end

      def validate_timezone!(tz)
        raise ValidationError, 'Schedule timezone is required' if blank?(tz)

        tz_str = tz.to_s.strip
        return if IANA_TIMEZONE_PATTERN.match?(tz_str)

        raise ValidationError, "Invalid timezone '#{tz_str}'. Must be a valid IANA timezone name."
      end

      def validate_retry_policy!(policy)
        return if policy.nil?

        attempts = extract_maximum_attempts(policy)
        return if attempts.nil?

        return if attempts.is_a?(Integer) && (0..185).cover?(attempts)

        raise ValidationError,
              "Invalid retry_policy maximum_attempts '#{attempts}'. Must be an integer between 0 and 185."
      end

      def extract_maximum_attempts(policy)
        if policy.is_a?(Hash)
          policy[:maximum_attempts] || policy['maximum_attempts'] ||
            policy[:attempts] || policy['attempts']
        elsif policy.respond_to?(:maximum_attempts)
          policy.maximum_attempts
        end
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end

      def freeze_value(val)
        case val
        when Hash
          freeze_hash(val)
        when Array
          val.map { |item| freeze_value(item) }.freeze
        when String
          val.dup.freeze
        else
          val.frozen? ? val : val.freeze
        end
      end

      def freeze_hash(hash)
        return {}.freeze if hash.nil?

        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = freeze_value(v)
        end.freeze
      end
    end
  end
end
