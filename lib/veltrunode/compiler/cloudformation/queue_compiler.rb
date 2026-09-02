# frozen_string_literal: true

require 'yaml'

module Veltrunode
  module Compiler
    module CloudFormation
      class QueueCompiler
        attr_reader :queue, :options, :context

        class << self
          def compile(queue, **)
            new(queue, **).to_h
          end

          def to_yaml(queue, **)
            new(queue, **).to_yaml
          end

          def logical_id_for(queue_name)
            base = pascalize(queue_name)
            base = 'Queue' if base.empty?
            base.end_with?('Queue') ? base : "#{base}Queue"
          end

          def pascalize(str)
            return '' if str.nil?

            str.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
              part[0].upcase + part[1..]
            end.join
          end
        end

        def initialize(queue, options: {}, context: {})
          @queue = queue
          @options = freeze_hash(options)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(queue_name_source)
        end

        def resource_type
          'AWS::SQS::Queue'
        end

        def queue_name_source
          if queue.respond_to?(:name)
            queue.name
          elsif queue.is_a?(Hash)
            queue[:name] || queue['name'] ||
              queue[:queue_name] || queue['queue_name'] ||
              queue[:logical_name] || queue['logical_name']
          else
            queue.to_s
          end
        end

        def properties
          props = {}

          q_name = explicit_queue_name
          props['QueueName'] = q_name if q_name

          retention = message_retention_period
          props['MessageRetentionPeriod'] = retention.to_i if retention

          vis_timeout = visibility_timeout
          props['VisibilityTimeout'] = vis_timeout.to_i if vis_timeout

          kms_key = kms_master_key_id
          props['KmsMasterKeyId'] = kms_key if kms_key

          deep_sort_keys(props)
        end

        def resource_definition
          res = {
            'Type' => resource_type
          }
          props = properties
          res['Properties'] = props unless props.empty?
          deep_sort_keys(res)
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

        def explicit_queue_name
          val = extract_prop(:queue_name) || extract_prop(:name) ||
                (queue.is_a?(String) || queue.is_a?(Symbol) ? queue : nil)
          return val.to_s if options[:explicit_name] || options['explicit_name']

          nil
        end

        def message_retention_period
          extract_prop(:message_retention_period) || extract_prop(:retention_period) ||
            options[:message_retention_period] || options['message_retention_period']
        end

        def visibility_timeout
          extract_prop(:visibility_timeout) || options[:visibility_timeout] || options['visibility_timeout']
        end

        def kms_master_key_id
          extract_prop(:kms_master_key_id) || extract_prop(:kms_key_id) ||
            options[:kms_master_key_id] || options['kms_master_key_id']
        end

        def extract_prop(key)
          if queue.respond_to?(key)
            queue.public_send(key)
          elsif queue.is_a?(Hash)
            queue[key.to_sym] || queue[key.to_s]
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
          return {}.freeze if hash.nil?

          hash.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = v
          end.freeze
        end
      end
    end
  end
end
