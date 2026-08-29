# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'function_compiler'
require_relative 'role_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      class ScheduleCompiler
        attr_reader :schedule, :defaults, :context

        class << self
          def compile(schedule, **)
            new(schedule, **).to_h
          end

          def to_yaml(schedule, **)
            new(schedule, **).to_yaml
          end

          def logical_id_for(schedule_name)
            base = pascalize(schedule_name)
            base = 'Schedule' if base.empty?
            base.end_with?('Schedule') ? base : "#{base}Schedule"
          end

          def pascalize(str)
            return '' if str.nil?

            str.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
              part[0].upcase + part[1..]
            end.join
          end
        end

        def initialize(schedule, defaults: {}, context: {})
          @schedule = schedule
          @defaults = freeze_hash(defaults)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(schedule.name)
        end

        def resource_type
          'AWS::Scheduler::Schedule'
        end

        def properties
          props = {
            'ScheduleExpression' => format_schedule_expression,
            'State' => format_state,
            'FlexibleTimeWindow' => format_flexible_time_window,
            'Target' => format_target
          }

          tz = format_timezone
          props['ScheduleExpressionTimezone'] = tz if tz

          deep_sort_keys(props)
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => properties
          }
        end

        def to_h
          deep_sort_keys({
                           logical_id => resource_definition
                         })
        end

        def to_yaml
          sorted_hash = to_h
          YAML.dump(sorted_hash)
        end

        private

        def format_schedule_expression
          expr = schedule.expression.to_s.strip
          type = schedule.expression_type.to_s.to_sym

          case type
          when :cron
            expr.start_with?('cron(') && expr.end_with?(')') ? expr : "cron(#{expr})"
          when :rate
            expr.start_with?('rate(') && expr.end_with?(')') ? expr : "rate(#{expr})"
          when :at
            expr.start_with?('at(') && expr.end_with?(')') ? expr : "at(#{expr})"
          else
            expr
          end
        end

        def format_state
          st = schedule.state.to_s.upcase
          %w[ENABLED DISABLED].include?(st) ? st : 'ENABLED'
        end

        def format_timezone
          tz = schedule.timezone
          return nil if tz.nil? || tz.to_s.strip.empty?

          tz.to_s.strip
        end

        def format_flexible_time_window
          flex = schedule.flexible_window || {}
          mode_val = (flex[:mode] || flex['mode'] || 'off').to_s.upcase
          mode_str = mode_val == 'FLEXIBLE' ? 'FLEXIBLE' : 'OFF'

          res = { 'Mode' => mode_str }

          if mode_str == 'FLEXIBLE'
            win = flex[:maximum_window_in_minutes] || flex['maximum_window_in_minutes'] ||
                  flex[:maximum_window] || flex['maximum_window']
            res['MaximumWindowInMinutes'] = win.to_i if win
          end

          res
        end

        def format_target
          target = {
            'Arn' => resolve_target_arn,
            'RoleArn' => resolve_role_arn
          }

          input_val = format_input
          target['Input'] = input_val if input_val

          retry_pol = format_retry_policy
          target['RetryPolicy'] = retry_pol if retry_pol && !retry_pol.empty?

          dlq_cfg = format_dead_letter_config
          target['DeadLetterConfig'] = dlq_cfg if dlq_cfg && !dlq_cfg.empty?

          target
        end

        def resolve_target_arn
          return context[:target_function_arn] if context[:target_function_arn]
          return context['target_function_arn'] if context['target_function_arn']

          target_fn = schedule.target_function.to_s
          if target_fn.start_with?('arn:')
            target_fn
          else
            fn_logical_id = FunctionCompiler.logical_id_for(target_fn)
            { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] }
          end
        end

        def resolve_role_arn
          return context[:execution_role_arn] if context[:execution_role_arn]
          return context['execution_role_arn'] if context['execution_role_arn']

          exec_role = schedule.execution_role
          return default_role_arn if exec_role.nil?

          format_explicit_role_arn(exec_role)
        end

        def default_role_arn
          role_logical_id = RoleCompiler.logical_id_for_schedule(schedule.name)
          { 'Fn::GetAtt' => [role_logical_id, 'Arn'] }
        end

        def format_explicit_role_arn(exec_role)
          return exec_role if exec_role.is_a?(Hash)
          return exec_role.to_s unless exec_role.is_a?(String)
          return exec_role if exec_role.start_with?('arn:')

          role_id = self.class.pascalize(exec_role)
          role_id = "#{role_id}Role" unless role_id.end_with?('Role')
          { 'Fn::GetAtt' => [role_id, 'Arn'] }
        end

        def format_input
          inp = schedule.input
          return nil if inp.nil?

          if inp.is_a?(String)
            inp.strip.empty? ? nil : inp
          elsif inp.is_a?(Hash) || inp.is_a?(Array)
            JSON.generate(inp)
          else
            inp.to_s
          end
        end

        def format_retry_policy
          policy = schedule.retry_policy
          return nil if policy.nil?

          res = {}

          attempts = extract_attempts(policy)
          res['MaximumRetryAttempts'] = attempts.to_i if attempts

          event_age = extract_event_age(policy)
          res['MaximumEventAgeInSeconds'] = event_age.to_i if event_age

          res
        end

        def extract_attempts(policy)
          if policy.is_a?(Hash)
            policy[:maximum_attempts] || policy['maximum_attempts'] ||
              policy[:maximum_retry_attempts] || policy['maximum_retry_attempts'] ||
              policy[:attempts] || policy['attempts']
          elsif policy.respond_to?(:maximum_attempts)
            policy.maximum_attempts
          end
        end

        def extract_event_age(policy)
          if policy.is_a?(Hash)
            policy[:maximum_event_age_in_seconds] || policy['maximum_event_age_in_seconds'] ||
              policy[:maximum_event_age] || policy['maximum_event_age'] ||
              policy[:event_age_in_seconds] || policy['event_age_in_seconds'] ||
              policy[:event_age] || policy['event_age']
          elsif policy.respond_to?(:maximum_event_age_in_seconds)
            policy.maximum_event_age_in_seconds
          end
        end

        def format_dead_letter_config
          dlq = schedule.dlq
          return nil if dlq.nil?

          arn = if dlq.is_a?(String)
                  if dlq.start_with?('arn:')
                    dlq
                  else
                    q_id = self.class.pascalize(dlq)
                    q_id = "#{q_id}Queue" unless q_id.end_with?('Queue')
                    { 'Fn::GetAtt' => [q_id, 'Arn'] }
                  end
                elsif dlq.is_a?(Hash)
                  dlq
                else
                  dlq.to_s
                end

          { 'Arn' => arn }
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.keys.sort_by(&:to_s).to_h do |k|
              [k.to_s, deep_sort_keys(obj[k])]
            end
          when Array
            obj.map { |v| deep_sort_keys(v) }
          else
            obj
          end
        end

        def freeze_hash(hash)
          return {}.freeze if hash.nil?

          hash.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = v
          end.freeze
        end
      end
    end
  end
end
