# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'DSL rest_api support' do
  it 'supports referencing an existing REST API ID and resource IDs with stage association' do
    app = Veltrunode.application 'enterprise-rest-api' do
      rest_api rest_api_id: ref(:corporate_rest_api_id), stage_name: 'prod' do
        get '/users', resource_id: ref(:users_resource_id), to: :list_users
        post '/users', resource_id: ref(:users_resource_id), to: :create_user, api_key_required: true
        delete resource_id: 'res-user-detail', to: :delete_user, authorization_type: 'AWS_IAM'
      end

      function :list_users do
        handler 'users.list'
        runtime 'ruby3.3'
      end
    end

    expect(app.rest_api?).to be true
    api = app.rest_api
    expect(api.external_rest_api?).to be true
    expect(api.rest_api_id).to be_a(Veltrunode::DSL::Reference)
    expect(api.rest_api_id.name).to eq(:corporate_rest_api_id)
    expect(api.stage_name).to eq('prod')
    expect(api.methods.size).to eq(3)

    expect(api.methods[0].method).to eq('GET')
    expect(api.methods[0].path).to eq('/users')
    expect(api.methods[0].resource_id.name).to eq(:users_resource_id)
    expect(api.methods[0].to).to eq('list_users')

    expect(api.methods[1].method).to eq('POST')
    expect(api.methods[1].api_key_required?).to be true

    expect(api.methods[2].method).to eq('DELETE')
    expect(api.methods[2].resource_id).to eq('res-user-detail')
    expect(api.methods[2].authorization_type).to eq('AWS_IAM')
  end

  it 'supports OpenAPI schema specification and block-based rest_api configuration' do
    app = Veltrunode.application 'openapi-app' do
      rest_api :orders_api do
        openapi bucket: 'my-spec-bucket', key: 'openapi/orders.yaml'
        description 'Orders Enterprise REST API'
        stage 'v1'
        tracing_enabled true
        stage_variables env: 'production'

        get '/orders', resource_id: ref(:orders_resource_id), to: :list_orders
        method :post, '/orders', resource_id: ref(:orders_resource_id), to: :create_order
      end
    end

    api = app.rest_api
    expect(api.name).to eq('orders_api')
    expect(api.openapi?).to be true
    expect(api.openapi).to eq('bucket' => 'my-spec-bucket', 'key' => 'openapi/orders.yaml')
    expect(api.description).to eq('Orders Enterprise REST API')
    expect(api.stage_name).to eq('v1')
    expect(api.tracing_enabled?).to be true
    expect(api.stage_variables).to eq('env' => 'production')
    expect(api.methods.size).to eq(2)
  end
end
