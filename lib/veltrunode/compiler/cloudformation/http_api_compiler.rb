# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::ApiGatewayV2 (Api, Stage, Integration, Route) および AWS::Lambda::Permission の CloudFormation コンパイラ
      class HttpApiCompiler
        attr_reader :http_api, :context

        class << self
          def compile(http_api, **)
            new(http_api, **).to_h
          end

          def to_yaml(http_api, **)
            new(http_api, **).to_yaml
          end

          def logical_id_for(api_name = nil)
            LogicalId.for_http_api(api_name)
          end

          def stage_logical_id_for(api_name = nil, stage_name = nil)
            LogicalId.for_http_api_stage(api_name, stage_name)
          end

          def integration_logical_id_for(function_name, api_name = nil)
            LogicalId.for_http_api_integration(function_name, api_name)
          end

          def route_logical_id_for(method, path, api_name = nil)
            LogicalId.for_http_api_route(method, path, api_name)
          end

          def permission_logical_id_for(function_name, api_name = nil)
            LogicalId.for_http_api_permission(function_name, api_name)
          end
        end

        def initialize(http_api, context: {})
          @http_api = http_api
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(http_api.name)
        end
        alias api_logical_id logical_id

        def stage_logical_id
          self.class.stage_logical_id_for(http_api.name, http_api.stage_name)
        end

        def api_resource_definition
          props = {
            'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{logical_id}" },
            'ProtocolType' => 'HTTP'
          }
          props['Description'] = http_api.description if http_api.description
          props['CorsConfiguration'] = http_api.cors.to_cfn_properties if http_api.cors?

          {
            'Type' => 'AWS::ApiGatewayV2::Api',
            'Properties' => deep_sort_keys(props)
          }
        end

        def stage_resource_definition
          {
            'Type' => 'AWS::ApiGatewayV2::Stage',
            'Properties' => deep_sort_keys(
              'ApiId' => { 'Ref' => logical_id },
              'AutoDeploy' => http_api.auto_deploy?,
              'StageName' => http_api.stage_name
            )
          }
        end

        def integration_resource_definition(route)
          fn_logical_id = FunctionCompiler.logical_id_for(route.target_function)

          {
            'Type' => 'AWS::ApiGatewayV2::Integration',
            'Properties' => deep_sort_keys(
              'ApiId' => { 'Ref' => logical_id },
              'IntegrationType' => 'AWS_PROXY',
              'IntegrationUri' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
              'PayloadFormatVersion' => route.payload_format_version
            )
          }
        end

        def route_resource_definition(route, integration_id)
          {
            'Type' => 'AWS::ApiGatewayV2::Route',
            'Properties' => deep_sort_keys(
              'ApiId' => { 'Ref' => logical_id },
              'RouteKey' => route.route_key,
              'Target' => {
                'Fn::Join' => [
                  '/',
                  [
                    'integrations',
                    { 'Ref' => integration_id }
                  ]
                ]
              }
            )
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
              'SourceArn' => {
                'Fn::Sub' => "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${#{logical_id}}/*/*"
              }
            )
          }
        end

        def to_h
          resources = {
            logical_id => api_resource_definition,
            stage_logical_id => stage_resource_definition
          }

          http_api.routes.each do |route|
            integration_id = self.class.integration_logical_id_for(route.target_function, http_api.name)
            resources[integration_id] ||= integration_resource_definition(route)

            route_id = self.class.route_logical_id_for(route.method, route.path, http_api.name)
            resources[route_id] = route_resource_definition(route, integration_id)

            perm_id = self.class.permission_logical_id_for(route.target_function, http_api.name)
            resources[perm_id] ||= permission_resource_definition(route.target_function)
          end

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

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
