# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::Events::Rule および AWS::Lambda::Permission リソースの CloudFormation コンパイラ
      class EventRuleCompiler
        attr_reader :function, :event_source, :context

        class << self
          def compile(function, event_source, **)
            new(function, event_source, **).to_h
          end

          def to_yaml(function, event_source, **)
            new(function, event_source, **).to_yaml
          end

          def logical_id_for(function_name, rule_identifier = nil)
            LogicalId.for_event_rule(function_name, rule_identifier)
          end

          def permission_logical_id_for(function_name, rule_identifier = nil)
            LogicalId.for_events_permission(function_name, rule_identifier)
          end
        end

        def initialize(function, event_source, context: {})
          @function = function
          @event_source = event_source
          @context = freeze_hash(context)
        end

        def logical_id
          fn_name = extract_name(function)
          self.class.logical_id_for(fn_name, event_source.rule_identifier)
        end

        def permission_logical_id
          fn_name = extract_name(function)
          self.class.permission_logical_id_for(fn_name, event_source.rule_identifier)
        end

        def resource_type
          'AWS::Events::Rule'
        end

        def properties
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          target_entry = {
            'Arn' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
            'Id' => "#{fn_logical_id}Target"
          }
          if event_source.input
            target_entry['Input'] = if event_source.input.is_a?(String)
                                      event_source.input
                                    else
                                      JSON.generate(deep_sort_keys(event_source.input))
                                    end
          end

          props = {
            'EventPattern' => event_source.pattern,
            'State' => event_source.cfn_state,
            'Targets' => [target_entry]
          }

          props['EventBusName'] = resolve_event_bus_name(event_source.bus) if event_source.bus
          props['Description'] = event_source.description if event_source.description

          deep_sort_keys(props)
        end

        def rule_resource_definition
          {
            'Type' => resource_type,
            'Properties' => properties
          }
        end
        alias resource_definition rule_resource_definition

        def permission_resource_definition
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          {
            'Type' => 'AWS::Lambda::Permission',
            'Properties' => deep_sort_keys(
              'Action' => 'lambda:InvokeFunction',
              'FunctionName' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
              'Principal' => 'events.amazonaws.com',
              'SourceArn' => { 'Fn::GetAtt' => [logical_id, 'Arn'] }
            )
          }
        end

        def to_h
          deep_sort_keys(
            logical_id => rule_resource_definition,
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
          elsif !target.is_a?(Symbol) && target.respond_to?(:name)
            target.name
          else
            target.to_s
          end
        end

        def resolve_event_bus_name(bus)
          if bus.is_a?(Hash)
            ref_key = bus[:ref] || bus['ref']
            return { 'Ref' => LogicalId.pascalize(ref_key) } if ref_key

            return bus
          end

          return { 'Ref' => LogicalId.pascalize(bus.name) } if !bus.is_a?(Symbol) && bus.respond_to?(:name)

          bus.to_s.strip
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
