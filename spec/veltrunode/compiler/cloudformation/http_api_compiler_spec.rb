# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/http_api'
require 'veltrunode/compiler/cloudformation/http_api_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::HttpApiCompiler do
  describe '.compile' do
    it 'generates AWS::ApiGatewayV2::Api, Stage, Integration, Route, and AWS::Lambda::Permission' do
      http_api = Veltrunode::Model::HttpApi.new(
        :default,
        cors: {
          allow_origins: ['https://example.com'],
          allow_methods: %w[GET POST OPTIONS],
          allow_headers: %w[Content-Type Authorization],
          max_age: 86_400,
          allow_credentials: true
        },
        routes: [
          { method: :get, path: '/users', to: :list_users },
          { method: :post, path: '/users', to: :create_user },
          { method: :get, path: '/users/{id}', to: :list_users }
        ]
      )

      resources = described_class.compile(http_api)

      # 1. AWS::ApiGatewayV2::Api
      api = resources['HttpApi']
      expect(api).not_to be_nil
      expect(api['Type']).to eq('AWS::ApiGatewayV2::Api')
      expect(api['Properties']).to eq(
        'CorsConfiguration' => {
          'AllowCredentials' => true,
          'AllowHeaders' => %w[Content-Type Authorization],
          'AllowMethods' => %w[GET POST OPTIONS],
          'AllowOrigins' => ['https://example.com'],
          'MaxAge' => 86_400
        },
        'Name' => { 'Fn::Sub' => '${AWS::StackName}-HttpApi' },
        'ProtocolType' => 'HTTP'
      )

      # 2. AWS::ApiGatewayV2::Stage
      stage = resources['HttpApiStage']
      expect(stage).not_to be_nil
      expect(stage['Type']).to eq('AWS::ApiGatewayV2::Stage')
      expect(stage['Properties']).to eq(
        'ApiId' => { 'Ref' => 'HttpApi' },
        'AutoDeploy' => true,
        'StageName' => '$default'
      )

      # 3. AWS::ApiGatewayV2::Integration (deduplicated per function)
      list_int = resources['HttpApiListUsersIntegration']
      expect(list_int).not_to be_nil
      expect(list_int['Type']).to eq('AWS::ApiGatewayV2::Integration')
      expect(list_int['Properties']).to eq(
        'ApiId' => { 'Ref' => 'HttpApi' },
        'IntegrationType' => 'AWS_PROXY',
        'IntegrationUri' => { 'Fn::GetAtt' => %w[ListUsersFunction Arn] },
        'PayloadFormatVersion' => '2.0'
      )

      create_int = resources['HttpApiCreateUserIntegration']
      expect(create_int).not_to be_nil
      expect(create_int['Properties']['IntegrationUri']).to eq(
        'Fn::GetAtt' => %w[CreateUserFunction Arn]
      )

      # 4. AWS::ApiGatewayV2::Route
      get_users_route = resources['HttpApiGetUsersRoute']
      expect(get_users_route).not_to be_nil
      expect(get_users_route['Type']).to eq('AWS::ApiGatewayV2::Route')
      expect(get_users_route['Properties']).to eq(
        'ApiId' => { 'Ref' => 'HttpApi' },
        'RouteKey' => 'GET /users',
        'Target' => {
          'Fn::Join' => [
            '/',
            [
              'integrations',
              { 'Ref' => 'HttpApiListUsersIntegration' }
            ]
          ]
        }
      )

      get_user_id_route = resources['HttpApiGetUsersIdRoute']
      expect(get_user_id_route['Properties']['RouteKey']).to eq('GET /users/{id}')
      expect(get_user_id_route['Properties']['Target']).to eq(
        'Fn::Join' => [
          '/',
          [
            'integrations',
            { 'Ref' => 'HttpApiListUsersIntegration' }
          ]
        ]
      )

      post_users_route = resources['HttpApiPostUsersRoute']
      expect(post_users_route['Properties']['RouteKey']).to eq('POST /users')

      # 5. AWS::Lambda::Permission (deduplicated per function)
      perm = resources['ListUsersFunctionHttpApiPermission']
      expect(perm).not_to be_nil
      expect(perm['Type']).to eq('AWS::Lambda::Permission')
      expect(perm['Properties']).to eq(
        'Action' => 'lambda:InvokeFunction',
        'FunctionName' => { 'Fn::GetAtt' => %w[ListUsersFunction Arn] },
        'Principal' => 'apigateway.amazonaws.com',
        'SourceArn' => {
          'Fn::Sub' => 'arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${HttpApi}/*/*'
        }
      )
      expect(resources).to have_key('CreateUserFunctionHttpApiPermission')
    end
  end
end
