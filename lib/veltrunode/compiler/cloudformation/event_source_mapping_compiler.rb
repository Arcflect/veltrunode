# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::Lambda::EventSourceMapping リソースの CloudFormation コンパイラ
      class EventSourceMappingCompiler
        attr_reader :function, :event_source, :context

        class << self
          def compile(function, event_source, **)
            new(function, event_source, **).to_h
          end

          def to_yaml(function, event_source, **)
            new(function, event_source, **).to_yaml
          end

          def logical_id_for(function_name, source_identifier = nil)
            LogicalId.for_event_source_mapping(function_name, source_identifier)
          end
        end

        def initialize(function, event_source, context: {})
          @function = function
          @event_source = event_source
          @context = freeze_hash(context)
        end

        def logical_id
          fn_name = extract_name(function)
          id_part = if event_source.respond_to?(:source_identifier)
                      event_source.source_identifier
                    else
                      event_source.queue_identifier
                    end
          self.class.logical_id_for(fn_name, id_part)
        end

        def resource_type
          'AWS::Lambda::EventSourceMapping'
        end

        def properties
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          props = {
            'EventSourceArn' => resolve_event_source_arn,
            'FunctionName' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] }
          }

          if event_source.respond_to?(:starting_position) && event_source.starting_position
            props['StartingPosition'] = event_source.starting_position
          end
          props['BatchSize'] = event_source.batch_size.to_i if event_source.batch_size
          if event_source.maximum_batching_window_in_seconds
            props['MaximumBatchingWindowInSeconds'] = event_source.maximum_batching_window_in_seconds.to_i
          end

          props['FunctionResponseTypes'] = ['ReportBatchItemFailures'] if event_source.report_batch_item_failures?

          props['Enabled'] = event_source.enabled? unless event_source.enabled?.nil?

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

        def resolve_event_source_arn
          if event_source.respond_to?(:dynamodb_stream?) && event_source.dynamodb_stream?
            resolve_stream_arn(event_source.stream)
          else
            resolve_queue_arn(event_source.queue)
          end
        end

        def resolve_queue_arn(queue)
          return queue if queue.is_a?(Hash)

          q_str = queue.to_s.strip
          if q_str.start_with?('arn:')
            q_str
          else
            q_id = LogicalId.for_queue(q_str)
            { 'Fn::GetAtt' => [q_id, 'Arn'] }
          end
        end

        def resolve_stream_arn(stream)
          if stream.is_a?(Hash)
            ref_key = stream[:ref] || stream['ref'] || stream[:Ref] || stream['Ref']
            return { 'Ref' => LogicalId.pascalize(ref_key) } if ref_key

            return stream
          end

          return { 'Ref' => LogicalId.pascalize(stream.name) } if !stream.is_a?(Symbol) && stream.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(stream) } if stream.is_a?(Symbol)

          s_str = stream.to_s.strip
          if s_str.start_with?('arn:')
            s_str
          else
            { 'Ref' => s_str }
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
