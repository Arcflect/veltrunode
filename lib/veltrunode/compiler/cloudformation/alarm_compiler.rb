# frozen_string_literal: true

require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # CloudWatch メトリクスアラーム (AWS::CloudWatch::Alarm) の CloudFormation コンパイラ
      class AlarmCompiler
        attr_reader :function, :alarm, :context

        class << self
          def compile(function, alarm, context: {})
            new(function, alarm, context: context).to_h
          end

          def logical_id_for(function_name, metric)
            LogicalId.for_function_alarm(function_name, metric)
          end
        end

        def initialize(function, alarm, context: {})
          @function = function
          @alarm = alarm
          @context = freeze_hash(context)
        end

        def to_h
          {
            logical_id => resource_definition
          }
        end

        def logical_id
          self.class.logical_id_for(function_name, alarm.metric)
        end

        def resource_type
          'AWS::CloudWatch::Alarm'
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => deep_sort_keys(properties)
          }
        end

        def properties
          props = if alarm.respond_to?(:error_rate?) && alarm.error_rate?
                    build_error_rate_properties
                  else
                    build_standard_properties
                  end

          formatted_alarm_actions = format_actions(alarm.alarm_actions)
          props['AlarmActions'] = formatted_alarm_actions unless formatted_alarm_actions.empty?

          formatted_ok_actions = format_actions(alarm.ok_actions)
          props['OKActions'] = formatted_ok_actions unless formatted_ok_actions.empty?

          props
        end

        private

        def build_standard_properties
          {
            'AlarmDescription' => alarm_description,
            'Namespace' => 'AWS/Lambda',
            'MetricName' => metric_name,
            'Dimensions' => [
              {
                'Name' => 'FunctionName',
                'Value' => { 'Ref' => function_logical_id }
              }
            ],
            'Statistic' => alarm.statistic,
            'ComparisonOperator' => alarm.comparison_operator,
            'Threshold' => alarm.threshold,
            'EvaluationPeriods' => alarm.evaluation_periods,
            'Period' => alarm.period,
            'TreatMissingData' => alarm.treat_missing_data
          }
        end

        def build_error_rate_properties
          {
            'AlarmDescription' => alarm_description,
            'ComparisonOperator' => alarm.comparison_operator,
            'Threshold' => alarm.threshold,
            'EvaluationPeriods' => alarm.evaluation_periods,
            'TreatMissingData' => alarm.treat_missing_data,
            'Metrics' => [
              {
                'Id' => 'e1',
                'MetricStat' => {
                  'Metric' => {
                    'Namespace' => 'AWS/Lambda',
                    'MetricName' => 'Errors',
                    'Dimensions' => [
                      {
                        'Name' => 'FunctionName',
                        'Value' => { 'Ref' => function_logical_id }
                      }
                    ]
                  },
                  'Period' => alarm.period,
                  'Stat' => 'Sum'
                },
                'ReturnData' => false
              },
              {
                'Id' => 'i1',
                'MetricStat' => {
                  'Metric' => {
                    'Namespace' => 'AWS/Lambda',
                    'MetricName' => 'Invocations',
                    'Dimensions' => [
                      {
                        'Name' => 'FunctionName',
                        'Value' => { 'Ref' => function_logical_id }
                      }
                    ]
                  },
                  'Period' => alarm.period,
                  'Stat' => 'Sum'
                },
                'ReturnData' => false
              },
              {
                'Id' => 'm1',
                'Expression' => '100 * (e1 / MAX([i1, 1]))',
                'Label' => 'ErrorRate',
                'ReturnData' => true
              }
            ]
          }
        end

        def function_name
          function.respond_to?(:logical_name) ? function.logical_name : function.to_s
        end

        def function_logical_id
          FunctionCompiler.logical_id_for(function_name)
        end

        def metric_name
          case alarm.metric.to_sym
          when :errors
            'Errors'
          when :duration
            'Duration'
          when :throttles
            'Throttles'
          when :error_rate
            'ErrorRate'
          else
            LogicalId.pascalize(alarm.metric)
          end
        end

        def alarm_description
          "CloudWatch Alarm for #{function_name} #{metric_name}"
        end

        def format_actions(actions)
          Array(actions).map { |act| format_action(act) }.compact
        end

        def format_action(action)
          return action if action.is_a?(Hash)

          if action.respond_to?(:name)
            # DSL::Reference
            return { 'Ref' => LogicalId.pascalize(action.name) }
          end

          return { 'Ref' => LogicalId.pascalize(action) } if action.is_a?(Symbol)

          str = action.to_s.strip
          return nil if str.empty?

          if str.start_with?('arn:aws:')
            str
          else
            { 'Ref' => str }
          end
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
          hash.each_with_object({}) do |(k, v), memo|
            frozen_val = v.is_a?(Hash) ? freeze_hash(v) : v.to_s.freeze
            memo[k.to_s.freeze] = frozen_val
          end.freeze
        end
      end
    end
  end
end
