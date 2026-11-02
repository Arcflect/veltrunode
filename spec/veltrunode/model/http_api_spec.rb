# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/http_api'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::Model::HttpApi do
  describe Veltrunode::Model::HttpRoute do
    it 'normalizes method, path, target function, and route_key' do
      route = described_class.new(method: :get, path: '/users', to: :list_users)

      expect(route.method).to eq('GET')
      expect(route.http_method).to eq('GET')
      expect(route.path).to eq('/users')
      expect(route.target_function).to eq('list_users')
      expect(route.to).to eq('list_users')
      expect(route.route_key).to eq('GET /users')
      expect(route.payload_format_version).to eq('2.0')
    end

    it 'supports $default catch-all route key when method is ANY and path is $default' do
      route = described_class.new(method: :any, path: '$default', to: :catch_all)
      expect(route.route_key).to eq('$default')
    end

    it 'raises ArgumentError when method, path, or target is invalid' do
      expect do
        described_class.new(method: :invalid, path: '/users', to: :list_users)
      end.to raise_error(ArgumentError, /Unsupported HTTP method/)

      expect do
        described_class.new(method: :get, path: 'users', to: :list_users)
      end.to raise_error(ArgumentError, /HTTP API route path must start with/)

      expect do
        described_class.new(method: :get, path: '/users', to: nil)
      end.to raise_error(ArgumentError, /Target function \(to:\) must be specified/)
    end
  end

  describe Veltrunode::Model::HttpCors do
    it 'creates default wildcard CORS configuration from true' do
      cors = described_class.from(true)

      expect(cors.allow_origins).to eq(['*'])
      expect(cors.allow_methods).to eq(['*'])
      expect(cors.allow_headers).to eq(['*'])
      expect(cors.to_cfn_properties).to eq(
        'AllowOrigins' => ['*'],
        'AllowMethods' => ['*'],
        'AllowHeaders' => ['*']
      )
    end

    it 'normalizes custom CORS configuration and generates CloudFormation properties' do
      cors = described_class.from(
        allow_origins: ['https://example.com'],
        allow_methods: %i[get post options],
        allow_headers: %w[Content-Type Authorization],
        expose_headers: ['X-Request-Id'],
        max_age: 86_400,
        allow_credentials: true
      )

      expect(cors.allow_origins).to eq(['https://example.com'])
      expect(cors.allow_methods).to eq(%w[GET POST OPTIONS])
      expect(cors.allow_headers).to eq(%w[Content-Type Authorization])
      expect(cors.expose_headers).to eq(['X-Request-Id'])
      expect(cors.max_age).to eq(86_400)
      expect(cors.allow_credentials?).to be true
      expect(cors.to_cfn_properties).to eq(
        'AllowOrigins' => ['https://example.com'],
        'AllowMethods' => %w[GET POST OPTIONS],
        'AllowHeaders' => %w[Content-Type Authorization],
        'ExposeHeaders' => ['X-Request-Id'],
        'MaxAge' => 86_400,
        'AllowCredentials' => true
      )
    end
  end

  describe 'HttpApi initialization and serialization' do
    it 'builds an immutable HttpApi with routes, stage, and CORS' do
      api = described_class.new(
        :default,
        description: 'User Management API',
        cors: {
          allow_origins: ['https://app.example.com'],
          allow_methods: %w[GET POST]
        },
        routes: [
          { method: :get, path: '/users', to: :list_users },
          { method: :post, path: '/users', to: :create_user }
        ]
      )

      expect(api.name).to eq('default')
      expect(api.description).to eq('User Management API')
      expect(api.stage_name).to eq('$default')
      expect(api.default_stage?).to be true
      expect(api.auto_deploy?).to be true
      expect(api.cors?).to be true
      expect(api.routes?).to be true
      expect(api.routes.size).to eq(2)
      expect(api.routes.first.route_key).to eq('GET /users')

      hash = api.to_h
      expect(hash['name']).to eq('default')
      expect(hash['stage_name']).to eq('$default')
      expect(hash['cors']['allow_origins']).to eq(['https://app.example.com'])
      expect(hash['routes'].size).to eq(2)
    end

    it 'integrates with Model::Application' do
      api = described_class.new(routes: [{ method: :get, path: '/users', to: :list_users }])
      app = Veltrunode::Model::Application.new('api-app', http_api: api)

      expect(app.http_api?).to be true
      expect(app.http_api).to eq(api)
      expect(app.http_apis).to eq([api])
    end
  end
end
