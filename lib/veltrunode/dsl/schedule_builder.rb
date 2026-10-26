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

      def dead_letter_queue(name_or_arn = nil, arn: nil, name: nil, alarm: false, topic: nil, **kwargs, &)
        if block_given?
          target_name = name || (name_or_arn unless name_or_arn.to_s.start_with?('arn:'))
          builder = DlqBuilder.new(target_name, alarm: alarm, topic: topic)
          builder.instance_eval(&)
          cfg = builder.to_h
          cfg[:name] ||= "#{@name}_dlq" if cfg[:arn].nil? && cfg[:name].nil?
          @dlq = cfg
          return
        end

        opts = if name_or_arn.is_a?(Hash)
                 name_or_arn.merge(kwargs)
               elsif kwargs.empty? && name_or_arn && !alarm && !topic && arn.nil? && name.nil?
                 @dlq = preserve_secret(name_or_arn)
                 return
               else
                 target_name = name || (name_or_arn unless name_or_arn.to_s.start_with?('arn:'))
                 target_arn = arn || (name_or_arn if name_or_arn.to_s.start_with?('arn:'))
                 {
                   name: target_name,
                   arn: target_arn,
                   alarm: alarm,
                   topic: topic
                 }.compact.merge(kwargs)
               end

        if !opts[:alarm] && opts[:arn] && opts[:name].nil? && opts[:topic].nil?
          @dlq = preserve_secret(opts[:arn])
        elsif !opts[:alarm] && opts[:name] && opts[:arn].nil? && opts[:topic].nil?
          @dlq = preserve_secret(opts[:name])
        else
          opts[:name] ||= "#{@name}_dlq" if opts[:arn].nil? && opts[:name].nil?
          @dlq = opts
        end
      end
      alias dlq dead_letter_queue

      def execution_role(role)
        @execution_role = preserve_secret(role)
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

      private

      def preserve_secret(val)
        return val if val.is_a?(Hash)

        val.respond_to?(:secret?) && val.secret? ? val : val.to_s
      end
    end

    # Schedule の DLQ 設定用 DSL ビルダー
    class DlqBuilder < BaseBuilder
      attr_reader :name_val, :arn_val, :alarm_val, :topic_val

      def initialize(target_name = nil, alarm: false, topic: nil)
        super()
        @name_val = target_name
        @arn_val = nil
        @alarm_val = alarm
        @topic_val = topic
      end

      def name(val)
        @name_val = val
      end

      def arn(val)
        @arn_val = val
      end

      def alarm(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @alarm_val = val
      end

      def topic(val)
        @topic_val = val
      end

      def to_h
        res = {}
        res[:name] = @name_val if @name_val
        res[:arn] = @arn_val if @arn_val
        res[:alarm] = @alarm_val unless @alarm_val.nil?
        res[:topic] = @topic_val if @topic_val
        res
      end
    end
  end
end
