# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'
require_relative '../../model/function_url'

module Veltrunode
  module Compiler
    module CloudFormation
      # Lambda Function URL (AWS::Lambda::Url) およびパブリックアクセス許可 (AWS::Lambda::Permission) のコンパイラ
      class FunctionUrlCompiler
        attr_reader :function, :function_url, :context

        class << self
          def compile(function, function_url = nil, **)
            new(function, function_url, **).to_h
          end

          def to_yaml(function, function_url = nil, **)
            new(function, function_url, **).to_yaml
          end

          def logical_id_for(function_name)
            LogicalId.for_function_url(function_name)
          end

          def permission_logical_id_for(function_name)
            LogicalId.for_function_url_permission(function_name)
          end
        end

        def initialize(function, function_url = nil, context: {})
          @function = function
          @function_url = resolve_function_url(function, function_url)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(function_name)
        end
        alias url_logical_id logical_id

        def permission_logical_id
          self.class.permission_logical_id_for(function_name)
        end

        def url_resource_definition
          props = {
            'AuthType' => function_url.auth_type,
            'TargetFunctionArn' => { 'Fn::GetAtt' => [function_logical_id, 'Arn'] }
          }

          if function_url.cors?
            cors_props = function_url.cors.to_cfn_properties
            props['Cors'] = cors_props unless cors_props.empty?
          end

          props['InvokeMode'] = function_url.invoke_mode if function_url.invoke_mode
          props['Qualifier'] = function_url.qualifier if function_url.qualifier

          {
            'Type' => 'AWS::Lambda::Url',
            'Properties' => deep_sort_keys(props)
          }
        end

        def permission_resource_definition
          {
            'Type' => 'AWS::Lambda::Permission',
            'Properties' => deep_sort_keys(
              'Action' => 'lambda:InvokeFunctionUrl',
              'FunctionName' => { 'Fn::GetAtt' => [function_logical_id, 'Arn'] },
              'FunctionUrlAuthType' => 'NONE',
              'Principal' => '*'
            )
          }
        end

        def to_h
          return {} unless function_url

          resources = {
            logical_id => url_resource_definition
          }
          resources[permission_logical_id] = permission_resource_definition if function_url.public_access?

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def resolve_function_url(fn, explicit_url)
          return Model::FunctionUrl.from(explicit_url) if explicit_url
          return Model::FunctionUrl.from(fn.function_url) if fn.respond_to?(:function_url)

          nil
        end

        def function_name
          function.respond_to?(:logical_name) ? function.logical_name : function.to_s
        end

        def function_logical_id
          FunctionCompiler.logical_id_for(function_name)
        end

        def freeze_hash(hash)
          return {}.freeze if hash.nil?

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
