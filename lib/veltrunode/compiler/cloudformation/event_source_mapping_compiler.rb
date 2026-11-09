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
          if event_source.respond_to?(:parallelization_factor) && event_source.parallelization_factor
            props['ParallelizationFactor'] = event_source.parallelization_factor.to_i
          end
          if event_source.respond_to?(:bisect_batch_on_function_error) &&
             !event_source.bisect_batch_on_function_error.nil?
            props['BisectBatchOnFunctionError'] = event_source.bisect_batch_on_function_error
          end

          if event_source.respond_to?(:msk?) && event_source.msk?
            props['Topics'] = Array(event_source.topics) if event_source.topics && !event_source.topics.empty?
            if event_source.respond_to?(:consumer_group_id) && event_source.consumer_group_id
              props['AmazonManagedKafkaEventSourceConfig'] = {
                'ConsumerGroupId' => event_source.consumer_group_id
              }
            end
          elsif event_source.respond_to?(:mq?) && event_source.mq?
            props['Queues'] = Array(event_source.queues) if event_source.queues && !event_source.queues.empty?
          end

          sac = build_source_access_configurations
          props['SourceAccessConfigurations'] = sac unless sac.empty?

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
          if event_source.respond_to?(:msk?) && event_source.msk?
            resolve_stream_arn(event_source.cluster)
          elsif event_source.respond_to?(:mq?) && event_source.mq?
            resolve_stream_arn(event_source.broker)
          elsif (event_source.respond_to?(:dynamodb_stream?) && event_source.dynamodb_stream?) ||
                (event_source.respond_to?(:kinesis_stream?) && event_source.kinesis_stream?)
            resolve_stream_arn(event_source.stream)
          else
            resolve_queue_arn(event_source.queue)
          end
        end

        def build_source_access_configurations
          configs = []

          if event_source.respond_to?(:secret) && event_source.secret
            auth_type = if event_source.respond_to?(:auth_type) && event_source.auth_type
                          event_source.auth_type
                        elsif event_source.respond_to?(:mq?) && event_source.mq?
                          'BASIC_AUTH'
                        else
                          'SASL_SCRAM_512_AUTH'
                        end
            configs << {
              'Type' => auth_type,
              'URI' => resolve_stream_arn(event_source.secret)
            }
          end

          if event_source.respond_to?(:virtual_host) && event_source.virtual_host
            configs << {
              'Type' => 'VIRTUAL_HOST',
              'URI' => event_source.virtual_host.to_s
            }
          end

          if event_source.respond_to?(:subnet_ids) && event_source.subnet_ids
            Array(event_source.subnet_ids).each do |sub|
              configs << {
                'Type' => 'VPC_SUBNET',
                'URI' => format_vpc_access_uri('subnet', sub)
              }
            end
          end

          if event_source.respond_to?(:security_group_ids) && event_source.security_group_ids
            Array(event_source.security_group_ids).each do |sg|
              configs << {
                'Type' => 'VPC_SECURITY_GROUP',
                'URI' => format_vpc_access_uri('security_group', sg)
              }
            end
          end

          if event_source.respond_to?(:source_access_configurations) && event_source.source_access_configurations
            Array(event_source.source_access_configurations).each do |entry|
              uri_val = entry['URI'] || entry[:URI] || entry['uri'] || entry[:uri]
              resolved_uri = if uri_val.is_a?(String) && !uri_val.start_with?('arn:')
                               uri_val
                             else
                               resolve_stream_arn(uri_val)
                             end
              configs << {
                'Type' => (entry['Type'] || entry[:Type] || entry['type'] || entry[:type]).to_s,
                'URI' => resolved_uri
              }
            end
          end

          configs
        end

        def format_vpc_access_uri(prefix, val)
          return val if val.is_a?(Hash)

          if !val.is_a?(Symbol) && val.respond_to?(:name)
            return { 'Fn::Sub' => "#{prefix}:${#{LogicalId.pascalize(val.name)}}" }
          end
          return { 'Fn::Sub' => "#{prefix}:${#{LogicalId.pascalize(val)}}" } if val.is_a?(Symbol)

          s = val.to_s.strip
          s.start_with?("#{prefix}:") ? s : "#{prefix}:#{s}"
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
