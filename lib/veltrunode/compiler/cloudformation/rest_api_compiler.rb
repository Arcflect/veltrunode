# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::ApiGateway (RestApi, Method, Deployment, Stage) および AWS::Lambda::Permission の CloudFormation コンパイラ
      class RestApiCompiler
        attr_reader :rest_api, :context

        class << self
          def compile(rest_api, **)
            new(rest_api, **).to_h
          end

          def to_yaml(rest_api, **)
            new(rest_api, **).to_yaml
          end

          def logical_id_for(api_name = nil)
            LogicalId.for_rest_api(api_name)
          end

          def method_logical_id_for(http_method, resource_identifier, api_name = nil)
            LogicalId.for_rest_api_method(http_method, resource_identifier, api_name)
          end

          def deployment_logical_id_for(api_name = nil)
            LogicalId.for_rest_api_deployment(api_name)
          end

          def stage_logical_id_for(api_name = nil, stage_name = nil)
            LogicalId.for_rest_api_stage(api_name, stage_name)
          end

          def permission_logical_id_for(function_name, api_name = nil)
            LogicalId.for_rest_api_permission(function_name, api_name)
          end
        end

        def initialize(rest_api, context: {})
          @rest_api = rest_api
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(rest_api.name)
        end
        alias api_logical_id logical_id

        def deployment_logical_id
          self.class.deployment_logical_id_for(rest_api.name)
        end

        def stage_logical_id
          self.class.stage_logical_id_for(rest_api.name, rest_api.stage_name)
        end

        def resolved_rest_api_id
          return { 'Ref' => logical_id } if rest_api.managed_rest_api?

          resolve_ref_or_value(rest_api.rest_api_id)
        end

        def api_resource_definition
          props = {
            'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{logical_id}" }
          }
          props['Description'] = rest_api.description if rest_api.description
          apply_openapi_properties!(props, rest_api.openapi) if rest_api.openapi?

          {
            'Type' => 'AWS::ApiGateway::RestApi',
            'Properties' => deep_sort_keys(props)
          }
        end

        def method_resource_definition(rest_method)
          fn_logical_id = FunctionCompiler.logical_id_for(rest_method.target_function)

          props = {
            'ApiKeyRequired' => rest_method.api_key_required?,
            'AuthorizationType' => rest_method.authorization_type,
            'HttpMethod' => rest_method.method,
            'Integration' => {
              'IntegrationHttpMethod' => 'POST',
              'Type' => 'AWS_PROXY',
              'Uri' => {
                'Fn::Sub' => [
                  'arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${FunctionArn}/invocations',
                  { 'FunctionArn' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] } }
                ]
              }
            },
            'ResourceId' => resolve_resource_id(rest_method),
            'RestApiId' => resolved_rest_api_id
          }
          props['AuthorizerId'] = resolve_ref_or_value(rest_method.authorizer_id) if rest_method.authorizer_id

          {
            'Type' => 'AWS::ApiGateway::Method',
            'Properties' => deep_sort_keys(props)
          }
        end

        def permission_resource_definition(function_name)
          fn_logical_id = FunctionCompiler.logical_id_for(function_name)

          {
            'Type' => 'AWS::Lambda::Permission',
            'Properties' => deep_sort_keys(
              'Action' => 'lambda:InvokeFunction',
              'FunctionName' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
              'Principal' => 'apigateway.amazonaws.com',
              'SourceArn' => build_permission_source_arn(resolved_rest_api_id)
            )
          }
        end

        def deployment_resource_definition(method_logical_ids)
          defn = {
            'Type' => 'AWS::ApiGateway::Deployment',
            'Properties' => deep_sort_keys(
              'RestApiId' => resolved_rest_api_id,
              'StageName' => rest_api.stage_name
            )
          }
          defn['DependsOn'] = method_logical_ids.uniq.sort unless method_logical_ids.empty?
          defn
        end

        def stage_resource_definition
          props = {
            'DeploymentId' => { 'Ref' => deployment_logical_id },
            'RestApiId' => resolved_rest_api_id,
            'StageName' => rest_api.stage_name
          }
          props['TracingEnabled'] = rest_api.tracing_enabled unless rest_api.tracing_enabled.nil?
          props['Variables'] = rest_api.stage_variables if rest_api.stage_variables

          {
            'Type' => 'AWS::ApiGateway::Stage',
            'Properties' => deep_sort_keys(props)
          }
        end

        def to_h
          resources = {}
          resources[logical_id] = api_resource_definition if rest_api.managed_rest_api?

          method_ids = []
          rest_api.methods.each do |m|
            m_id = self.class.method_logical_id_for(m.method, m.resource_identifier, rest_api.name)
            resources[m_id] = method_resource_definition(m)
            method_ids << m_id

            perm_id = self.class.permission_logical_id_for(m.target_function, rest_api.name)
            resources[perm_id] ||= permission_resource_definition(m.target_function)
          end

          if rest_api.deployment?
            resources[deployment_logical_id] = deployment_resource_definition(method_ids)
            resources[stage_logical_id] = stage_resource_definition
          end

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def resolve_resource_id(rest_method)
          raw_res = rest_method.resource_id || rest_api.root_resource_id
          return { 'Fn::GetAtt' => [logical_id, 'RootResourceId'] } if raw_res.nil?

          resolve_ref_or_value(raw_res)
        end

        def resolve_ref_or_value(val)
          if val.is_a?(Hash)
            ref_key = val[:ref] || val['ref']
            return { 'Ref' => LogicalId.pascalize(ref_key) } if ref_key

            return val
          end

          return { 'Ref' => LogicalId.pascalize(val.name) } if !val.is_a?(Symbol) && val.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(val) } if val.is_a?(Symbol)

          val.to_s.strip
        end

        def build_permission_source_arn(api_ref)
          if api_ref.is_a?(String)
            { 'Fn::Sub' => "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:#{api_ref}/*/*/*" }
          elsif api_ref.is_a?(Hash) && api_ref['Ref']
            { 'Fn::Sub' => "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${#{api_ref['Ref']}}/*/*/*" }
          else
            {
              'Fn::Sub' => [
                'arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${RestApiId}/*/*/*',
                { 'RestApiId' => api_ref }
              ]
            }
          end
        end

        def apply_openapi_properties!(props, openapi_spec)
          if openapi_spec.is_a?(Hash)
            bucket = openapi_spec['bucket'] || openapi_spec['Bucket']
            key = openapi_spec['key'] || openapi_spec['Key']
            if bucket && key
              props['BodyS3Location'] = { 'Bucket' => bucket, 'Key' => key }
            else
              props['Body'] = openapi_spec
            end
          elsif openapi_spec.to_s.start_with?('s3://')
            without_scheme = openapi_spec.to_s.sub(%r{\As3://}, '')
            bucket, key = without_scheme.split('/', 2)
            props['BodyS3Location'] = { 'Bucket' => bucket, 'Key' => key.to_s }
          else
            props['Body'] = openapi_spec
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
