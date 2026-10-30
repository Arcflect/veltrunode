# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::SNS::Subscription および AWS::Lambda::Permission リソースの CloudFormation コンパイラ
      class SnsSubscriptionCompiler
        attr_reader :function, :event_source, :context

        class << self
          def compile(function, event_source, **)
            new(function, event_source, **).to_h
          end

          def to_yaml(function, event_source, **)
            new(function, event_source, **).to_yaml
          end

          def logical_id_for(function_name, topic_identifier = nil)
            LogicalId.for_sns_subscription(function_name, topic_identifier)
          end

          def permission_logical_id_for(function_name, topic_identifier = nil)
            LogicalId.for_sns_permission(function_name, topic_identifier)
          end
        end

        def initialize(function, event_source, context: {})
          @function = function
          @event_source = event_source
          @context = freeze_hash(context)
        end

        def logical_id
          fn_name = extract_name(function)
          self.class.logical_id_for(fn_name, event_source.topic_identifier)
        end

        def permission_logical_id
          fn_name = extract_name(function)
          self.class.permission_logical_id_for(fn_name, event_source.topic_identifier)
        end

        def resource_type
          'AWS::SNS::Subscription'
        end

        def properties
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          props = {
            'Endpoint' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
            'Protocol' => 'lambda',
            'TopicArn' => resolve_topic_arn(event_source.topic)
          }

          props['FilterPolicy'] = event_source.filter_policy if event_source.filter_policy
          props['FilterPolicyScope'] = event_source.filter_policy_scope if event_source.filter_policy_scope

          deep_sort_keys(props)
        end

        def subscription_resource_definition
          {
            'Type' => resource_type,
            'Properties' => properties
          }
        end
        alias resource_definition subscription_resource_definition

        def permission_resource_definition
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          {
            'Type' => 'AWS::Lambda::Permission',
            'Properties' => deep_sort_keys(
              'Action' => 'lambda:InvokeFunction',
              'FunctionName' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
              'Principal' => 'sns.amazonaws.com',
              'SourceArn' => resolve_topic_arn(event_source.topic)
            )
          }
        end

        def to_h
          deep_sort_keys(
            logical_id => subscription_resource_definition,
            permission_logical_id => permission_resource_definition
          )
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def extract_name(target)
          if target.respond_to?(:logical_name)
            target.logical_name
          elsif target.respond_to?(:name)
            target.name
          else
            target.to_s
          end
        end

        def resolve_topic_arn(topic)
          if topic.is_a?(Hash)
            ref_key = topic[:ref] || topic['ref']
            return { 'Ref' => LogicalId.pascalize(ref_key) } if ref_key

            return topic
          end

          return { 'Ref' => LogicalId.pascalize(topic.name) } if topic.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(topic) } if topic.is_a?(Symbol)

          t_str = topic.to_s.strip
          if t_str.start_with?('arn:')
            t_str
          else
            { 'Ref' => t_str }
          end
        end

        def freeze_hash(hash)
          hash.transform_values { |v| v.is_a?(Hash) ? freeze_hash(v) : v }.freeze
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), memo|
              memo[k] = deep_sort_keys(v)
            end.sort.to_h
          when Array
            obj.map { |item| deep_sort_keys(item) }
          else
            obj
          end
        end
      end
    end
  end
end
