# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/rest_api'
require 'veltrunode/compiler/cloudformation/rest_api_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::RestApiCompiler do
  describe '.compile' do
    it 'compiles existing REST API reference into Method, Permission, Deployment, and Stage without RestApi' do
      rest_api = Veltrunode::Model::RestApi.new(
        :corporate,
        rest_api_id: { 'Ref' => 'CorporateRestApiId' },
        stage_name: 'v1',
        tracing_enabled: true,
        stage_variables: { 'env' => 'production' },
        methods: [
          {
            method: :get,
            path: '/users',
            resource_id: { 'Ref' => 'UsersResourceId' },
            to: :list_users,
            api_key_required: true
          },
          {
            method: :post,
            path: '/users',
            resource_id: { 'Ref' => 'UsersResourceId' },
            to: :create_user,
            authorization_type: 'CUSTOM',
            authorizer_id: 'auth-999'
          },
          {
            method: :get,
            path: '/users/{id}',
            resource_id: 'user-id-res',
            to: :list_users
          }
        ]
      )

      resources = described_class.compile(rest_api)

      # Existing REST API is NOT created in the stack
      expect(resources).not_to have_key('CorporateRestApi')

      # 1. AWS::ApiGateway::Method
      get_users = resources['CorporateRestApiGetUsersMethod']
      expect(get_users).not_to be_nil
      expect(get_users['Type']).to eq('AWS::ApiGateway::Method')
      expect(get_users['Properties']).to eq(
        'ApiKeyRequired' => true,
        'AuthorizationType' => 'NONE',
        'HttpMethod' => 'GET',
        'Integration' => {
          'IntegrationHttpMethod' => 'POST',
          'Type' => 'AWS_PROXY',
          'Uri' => {
            'Fn::Sub' => [
              'arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${FunctionArn}/invocations',
              { 'FunctionArn' => { 'Fn::GetAtt' => %w[ListUsersFunction Arn] } }
            ]
          }
        },
        'ResourceId' => { 'Ref' => 'UsersResourceId' },
        'RestApiId' => { 'Ref' => 'CorporateRestApiId' }
      )

      post_users = resources['CorporateRestApiPostUsersMethod']
      expect(post_users['Properties']['AuthorizationType']).to eq('CUSTOM')
      expect(post_users['Properties']['AuthorizerId']).to eq('auth-999')

      # 2. AWS::Lambda::Permission (deduplicated per function)
      list_perm = resources['ListUsersFunctionCorporateRestApiPermission']
      expect(list_perm).not_to be_nil
      expect(list_perm['Type']).to eq('AWS::Lambda::Permission')
      expect(list_perm['Properties']).to eq(
        'Action' => 'lambda:InvokeFunction',
        'FunctionName' => { 'Fn::GetAtt' => %w[ListUsersFunction Arn] },
        'Principal' => 'apigateway.amazonaws.com',
        'SourceArn' => {
          'Fn::Sub' => 'arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${CorporateRestApiId}/*/*/*'
        }
      )
      expect(resources).to have_key('CreateUserFunctionCorporateRestApiPermission')

      # 3. AWS::ApiGateway::Deployment & Stage
      deployment = resources['CorporateRestApiDeployment']
      expect(deployment).not_to be_nil
      expect(deployment['Type']).to eq('AWS::ApiGateway::Deployment')
      expect(deployment['DependsOn']).to eq(
        %w[
          CorporateRestApiGetUsersIdMethod
          CorporateRestApiGetUsersMethod
          CorporateRestApiPostUsersMethod
        ]
      )
      expect(deployment['Properties']).to eq(
        'RestApiId' => { 'Ref' => 'CorporateRestApiId' },
        'StageName' => 'v1'
      )

      stage = resources['CorporateRestApiV1Stage']
      expect(stage).not_to be_nil
      expect(stage['Type']).to eq('AWS::ApiGateway::Stage')
      expect(stage['Properties']).to eq(
        'DeploymentId' => { 'Ref' => 'CorporateRestApiDeployment' },
        'RestApiId' => { 'Ref' => 'CorporateRestApiId' },
        'StageName' => 'v1',
        'TracingEnabled' => true,
        'Variables' => { 'env' => 'production' }
      )
    end

    it 'compiles managed REST API with OpenAPI specification (inline or S3)' do
      rest_api = Veltrunode::Model::RestApi.new(
        :default,
        description: 'OpenAPI REST API',
        openapi: 's3://my-api-specs/openapi.yaml',
        stage_name: 'prod',
        methods: [
          { method: :get, path: '/health', to: :health_check }
        ]
      )

      resources = described_class.compile(rest_api)

      api = resources['RestApi']
      expect(api).not_to be_nil
      expect(api['Type']).to eq('AWS::ApiGateway::RestApi')
      expect(api['Properties']).to eq(
        'BodyS3Location' => {
          'Bucket' => 'my-api-specs',
          'Key' => 'openapi.yaml'
        },
        'Description' => 'OpenAPI REST API',
        'Name' => { 'Fn::Sub' => '${AWS::StackName}-RestApi' }
      )

      method_res = resources['RestApiGetHealthMethod']
      expect(method_res['Properties']['RestApiId']).to eq('Ref' => 'RestApi')
      expect(method_res['Properties']['ResourceId']).to eq('Fn::GetAtt' => %w[RestApi RootResourceId])
    end
  end
end
