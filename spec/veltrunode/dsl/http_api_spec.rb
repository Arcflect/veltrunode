# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'DSL http_api support' do
  it 'supports http_api block with route definitions (get, post, put, patch, delete)' do
    app = Veltrunode.application 'users-api' do
      http_api do
        get '/users', to: :list_users
        post '/users', to: :create_user
        get '/users/{id}', to: :get_user
        put '/users/{id}', to: :update_user
        patch '/users/{id}', to: :patch_user
        delete '/users/{id}', to: :delete_user
      end

      function :list_users do
        handler 'users.list'
        runtime 'ruby3.3'
      end
    end

    expect(app.http_api?).to be true
    api = app.http_api
    expect(api.name).to eq('default')
    expect(api.stage_name).to eq('$default')
    expect(api.auto_deploy?).to be true
    expect(api.routes.size).to eq(6)

    expect(api.routes[0].route_key).to eq('GET /users')
    expect(api.routes[0].to).to eq('list_users')
    expect(api.routes[1].route_key).to eq('POST /users')
    expect(api.routes[1].to).to eq('create_user')
    expect(api.routes[2].route_key).to eq('GET /users/{id}')
    expect(api.routes[2].to).to eq('get_user')
    expect(api.routes[3].route_key).to eq('PUT /users/{id}')
    expect(api.routes[3].to).to eq('update_user')
    expect(api.routes[4].route_key).to eq('PATCH /users/{id}')
    expect(api.routes[4].to).to eq('patch_user')
    expect(api.routes[5].route_key).to eq('DELETE /users/{id}')
    expect(api.routes[5].to).to eq('delete_user')
  end

  it 'supports hash-based and block-based CORS configuration in http_api' do
    app = Veltrunode.application 'cors-api' do
      http_api do
        cors allow_origins: ['https://example.com', 'https://admin.example.com'],
             allow_methods: %w[GET POST OPTIONS],
             allow_headers: %w[Content-Type Authorization],
             expose_headers: ['X-Total-Count'],
             max_age: 3600,
             allow_credentials: true

        get '/items', to: :list_items
      end
    end

    cors = app.http_api.cors
    expect(cors).not_to be_nil
    expect(cors.allow_origins).to eq(['https://example.com', 'https://admin.example.com'])
    expect(cors.allow_methods).to eq(%w[GET POST OPTIONS])
    expect(cors.allow_headers).to eq(%w[Content-Type Authorization])
    expect(cors.expose_headers).to eq(['X-Total-Count'])
    expect(cors.max_age).to eq(3600)
    expect(cors.allow_credentials?).to be true
  end

  it 'supports block-based cors and cors true shorthand' do
    app = Veltrunode.application 'cors-block-api' do
      http_api :public_api do
        description 'Public HTTP API'
        stage_name 'v1'
        auto_deploy false

        cors do
          origins 'https://frontend.example.com'
          methods :get, :post
          headers 'Content-Type'
          max_age 600
          credentials true
        end

        any '/proxy/{proxy+}', to: :proxy_handler
        route 'HEAD /health', to: :health_check
      end
    end

    api = app.http_api
    expect(api.name).to eq('public_api')
    expect(api.description).to eq('Public HTTP API')
    expect(api.stage_name).to eq('v1')
    expect(api.auto_deploy?).to be false
    expect(api.cors.allow_origins).to eq(['https://frontend.example.com'])
    expect(api.cors.allow_methods).to eq(%w[GET POST])
    expect(api.cors.allow_headers).to eq(['Content-Type'])
    expect(api.cors.max_age).to eq(600)
    expect(api.cors.allow_credentials?).to be true
    expect(api.routes.map(&:route_key)).to eq(['ANY /proxy/{proxy+}', 'HEAD /health'])
  end
end
