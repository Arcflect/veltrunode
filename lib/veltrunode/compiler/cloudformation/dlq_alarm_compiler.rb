# frozen_string_literal: true

require_relative '../logical_id'

module Veltrunode
  module Compiler
    module CloudFormation
      # SQS DLQ メッセージ監視アラーム (AWS::CloudWatch::Alarm) の CloudFormation コンパイラ
      class DlqAlarmCompiler
        attr_reader :queue_name, :topic, :options, :context

        class << self
          def compile(queue_name, topic: nil, options: {}, context: {})
            new(queue_name, topic: topic, options: options, context: context).to_h
          end

          def logical_id_for(queue_name)
            LogicalId.for_queue_alarm(queue_name)
          end
        end

        def initialize(queue_name, topic: nil, options: {}, context: {})
          @queue_name = queue_name.to_s
          @topic = topic
          @options = freeze_hash(options)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(queue_name)
        end

        def resource_type
          'AWS::CloudWatch::Alarm'
        end

        def properties
          props = {
            'AlarmName' => alarm_name,
            'AlarmDescription' => alarm_description,
            'Namespace' => 'AWS/SQS',
            'MetricName' => 'ApproximateNumberOfMessagesVisible',
            'Dimensions' => [
              {
                'Name' => 'QueueName',
                'Value' => { 'Fn::GetAtt' => [queue_logical_id, 'QueueName'] }
              }
            ],
            'Statistic' => 'Maximum',
            'ComparisonOperator' => 'GreaterThanThreshold',
            'Threshold' => 0,
            'EvaluationPeriods' => 1,
            'Period' => 60,
            'TreatMissingData' => 'notBreaching'
          }

          formatted_actions = format_actions(topic)
          props['AlarmActions'] = formatted_actions unless formatted_actions.empty?

          deep_sort_keys(props)
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => properties
          }
        end

        def to_h
          {
            logical_id => resource_definition
          }
        end

        private

        def queue_logical_id
          LogicalId.for_queue(queue_name)
        end

        def alarm_name
          { 'Fn::Sub' => "${AWS::StackName}-#{logical_id}" }
        end

        def alarm_description
          "CloudWatch Alarm for SQS DLQ #{queue_name} ApproximateNumberOfMessagesVisible"
        end

        def format_actions(actions)
          Array(actions).compact.map { |act| format_action(act) }.compact
        end

        def format_action(action)
          return action if action.is_a?(Hash)

          return { 'Ref' => LogicalId.pascalize(action.name) } if action.respond_to?(:name)
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
