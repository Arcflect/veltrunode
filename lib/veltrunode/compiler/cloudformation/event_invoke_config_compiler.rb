# frozen_string_literal: true

require_relative '../logical_id'
require_relative 'function_compiler'
require_relative '../../model/async_invoke_config'

module Veltrunode
  module Compiler
    module CloudFormation
      # Lambda 非同期呼び出し設定 (AWS::Lambda::EventInvokeConfig) の CloudFormation コンパイラ
      class EventInvokeConfigCompiler
        attr_reader :function, :context

        class << self
          def compile(function, context: {})
            new(function, context: context).to_h
          end

          def logical_id_for(function_name)
            LogicalId.for_event_invoke_config(function_name)
          end
        end

        def initialize(function, context: {})
          @function = function
          @context = freeze_hash(context)
        end

        def to_h
          return {} unless async_invoke

          {
            logical_id => resource_definition
          }
        end

        def logical_id
          self.class.logical_id_for(function_name)
        end

        def resource_type
          'AWS::Lambda::EventInvokeConfig'
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => deep_sort_keys(properties)
          }
        end

        def properties
          props = {
            'FunctionName' => { 'Ref' => function_logical_id },
            'Qualifier' => async_invoke.qualifier || '$LATEST'
          }

          props['MaximumRetryAttempts'] = async_invoke.max_retries unless async_invoke.max_retries.nil?
          props['MaximumEventAgeInSeconds'] = async_invoke.max_age unless async_invoke.max_age.nil?

          if async_invoke.destination_config?
            dest_config = {}
            if async_invoke.on_success
              dest_config['OnSuccess'] = {
                'Destination' => format_destination(async_invoke.on_success)
              }
            end
            if async_invoke.on_failure
              dest_config['OnFailure'] = {
                'Destination' => format_destination(async_invoke.on_failure)
              }
            end
            props['DestinationConfig'] = dest_config
          end

          props
        end

        def format_destination(dest)
          return nil if dest.nil?

          if dest.is_a?(Hash)
            if dest.key?(:ref) || dest.key?('ref')
              ref_key = dest[:ref] || dest['ref']
              return { 'Ref' => LogicalId.pascalize(ref_key) }
            end
            return deep_sort_keys(dest)
          end

          dest_str = dest.to_s.strip
          if dest.is_a?(Symbol) || (!dest_str.empty? && !dest_str.start_with?('arn:') && !dest_str.include?(':'))
            resolve_symbolic_destination(dest)
          else
            dest_str
          end
        end

        private

        def function_name
          function.respond_to?(:logical_name) ? function.logical_name : function.to_s
        end

        def function_logical_id
          FunctionCompiler.logical_id_for(function_name)
        end

        def async_invoke
          function.respond_to?(:async_invoke) ? function.async_invoke : nil
        end

        def resolve_symbolic_destination(target)
          target_str = target.to_s
          dest_type = Model::AsyncInvokeConfig.destination_type(target)

          case dest_type
          when :sqs
            q_id = LogicalId.for_queue(target_str)
            { 'Fn::GetAtt' => [q_id, 'Arn'] }
          when :lambda
            fn_id = LogicalId.for_function(target_str)
            { 'Fn::GetAtt' => [fn_id, 'Arn'] }
          else
            param_key = LogicalId.pascalize(target_str)
            param_key = "#{param_key}Arn" unless param_key.end_with?('Arn')
            { 'Ref' => param_key }
          end
        end

        def freeze_hash(hash)
          return {}.freeze if hash.nil?

          hash.transform_keys(&:to_s).freeze
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.keys.sort_by(&:to_s).to_h do |key|
              [key, deep_sort_keys(obj[key])]
            end
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
