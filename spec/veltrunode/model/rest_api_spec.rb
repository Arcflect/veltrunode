# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/reference'
require 'veltrunode/model/rest_api'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::Model::RestApi do
  describe Veltrunode::Model::RestMethod do
    it 'normalizes HTTP method, path, resource_id, target function, and authorization options' do
      res_ref = Veltrunode::DSL::Reference.new(:users_resource_id)
      method = described_class.new(
        method: :get,
        path: '/users',
        resource_id: res_ref,
        to: :list_users,
        authorization_type: 'aws_iam',
        api_key_required: true
      )

      expect(method.method).to eq('GET')
      expect(method.http_method).to eq('GET')
      expect(method.path).to eq('/users')
      expect(method.resource_id).to eq(res_ref)
      expect(method.target_function).to eq('list_users')
      expect(method.to).to eq('list_users')
      expect(method.authorization_type).to eq('AWS_IAM')
      expect(method.api_key_required?).to be true
      expect(method.resource_identifier).to eq('users')
    end

    it 'derives resource_identifier from resource_id when path is omitted' do
      method = described_class.new(
        method: :post,
        resource_id: Veltrunode::DSL::Reference.new(:orders_resource),
        to: :create_order
      )

      expect(method.resource_identifier).to eq('orders_resource')
      expect(method.authorization_type).to eq('NONE')
      expect(method.api_key_required?).to be false
    end

    it 'raises ArgumentError on invalid method, path, target, or authorization_type' do
      expect do
        described_class.new(method: :invalid, resource_id: 'res1', to: :fn)
      end.to raise_error(ArgumentError, /Unsupported HTTP method/)

      expect do
        described_class.new(method: :get, path: 'users', resource_id: 'res1', to: :fn)
      end.to raise_error(ArgumentError, /REST API method path must start with/)

      expect do
        described_class.new(method: :get, resource_id: 'res1', to: nil)
      end.to raise_error(ArgumentError, /Target function \(to:\) must be specified/)

      expect do
        described_class.new(method: :get, resource_id: 'res1', to: :fn, authorization_type: :oauth2)
      end.to raise_error(ArgumentError, /Invalid authorization_type/)
    end
  end

  describe 'RestApi initialization and validation' do
    it 'builds an immutable RestApi referencing an existing REST API ID and resource IDs' do
      api_ref = Veltrunode::DSL::Reference.new(:corporate_rest_api_id)
      res_ref = Veltrunode::DSL::Reference.new(:users_resource_id)

      api = described_class.new(
        :corporate,
        rest_api_id: api_ref,
        stage_name: 'v1',
        tracing_enabled: true,
        methods: [
          { method: :get, path: '/users', resource_id: res_ref, to: :list_users },
          { method: :post, path: '/users', resource_id: res_ref, to: :create_user, api_key_required: true }
        ]
      )

      expect(api.name).to eq('corporate')
      expect(api.rest_api_id).to eq(api_ref)
      expect(api.external_rest_api?).to be true
      expect(api.managed_rest_api?).to be false
      expect(api.stage_name).to eq('v1')
      expect(api.tracing_enabled?).to be true
      expect(api.deployment?).to be true
      expect(api.methods.size).to eq(2)
      expect(api.to_h['rest_api_id']).to eq('corporate_rest_api_id')
      expect(api.to_h['methods'].size).to eq(2)
    end

    it 'raises ArgumentError when referencing an existing REST API without resource_id or root_resource_id' do
      expect do
        described_class.new(
          rest_api_id: 'abc12345',
          methods: [{ method: :get, path: '/users', to: :list_users }]
        )
      end.to raise_error(ArgumentError, /resource_id must be specified for REST API method/)
    end

    it 'supports OpenAPI schema specification and integrates with Model::Application' do
      api = described_class.new(
        :openapi_service,
        openapi: 'openapi/spec.yaml',
        stage_name: 'prod',
        methods: [
          { method: :get, path: '/items', to: :list_items }
        ]
      )

      expect(api.openapi?).to be true
      expect(api.managed_rest_api?).to be true
      expect(api.openapi).to eq('openapi/spec.yaml')

      app = Veltrunode::Model::Application.new('rest-app', rest_api: api)
      expect(app.rest_api?).to be true
      expect(app.rest_api).to eq(api)
      expect(app.rest_apis).to eq([api])
    end
  end
end
