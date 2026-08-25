# frozen_string_literal: true

require 'yaml'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      class LogGroupCompiler
        DEFAULT_RETENTION_DAYS = 30

        attr_reader :function, :defaults, :retention_days, :context

        class << self
          def compile(function, **)
            new(function, **).to_h
          end

          def to_yaml(function, **)
            new(function, **).to_yaml
          end

          def logical_id_for(logical_name)
            str = logical_name.to_s
            return str if str.end_with?('LogGroup')

            fn_logical_id = FunctionCompiler.logical_id_for(str)
            fn_logical_id.end_with?('LogGroup') ? fn_logical_id : "#{fn_logical_id}LogGroup"
          end
        end

        def initialize(function, defaults: {}, retention_days: nil, context: {})
          @function = function
          @defaults = freeze_hash(defaults)
          @context = freeze_hash(context)
          @retention_days = resolve_retention_days(retention_days)
        end

        def logical_id
          self.class.logical_id_for(function.logical_name)
        end

        def resource_type
          'AWS::Logs::LogGroup'
        end

        def log_group_name
          "/aws/lambda/#{function.logical_name}"
        end

        def properties
          props = {
            'LogGroupName' => log_group_name
          }
          props['RetentionInDays'] = retention_days if retention_days

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

        def resolve_retention_days(explicit_days)
          return explicit_days.to_i if explicit_days

          if function.respond_to?(:logging) && function.logging
            fn_log = function.logging
            if fn_log.is_a?(Hash)
              days = fn_log[:retention_days] || fn_log['retention_days'] ||
                     fn_log[:retention_in_days] || fn_log['retention_in_days']
              return days.to_i if days
            elsif fn_log.is_a?(Numeric) || fn_log.is_a?(String)
              return fn_log.to_i if fn_log.to_i.positive?
            end
          end

          defaults_logs = defaults[:logs] || defaults['logs'] ||
                          context[:defaults]&.fetch(:logs, nil) || context[:defaults]&.fetch('logs', nil)
          if defaults_logs.is_a?(Hash)
            days = defaults_logs[:retention_days] || defaults_logs['retention_days'] ||
                   defaults_logs[:retention_in_days] || defaults_logs['retention_in_days']
            return days.to_i if days
          end

          def_retention = defaults[:retention_days] || defaults['retention_days'] ||
                          defaults[:retention_in_days] || defaults['retention_in_days']
          return def_retention.to_i if def_retention

          DEFAULT_RETENTION_DAYS
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
