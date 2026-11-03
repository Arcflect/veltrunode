# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/rest_api'

module Veltrunode
  module DSL
    # rest_api ブロックを構築するビルダークラス
    class RestApiBuilder < BaseBuilder
      def initialize(
        name = :default,
        rest_api_id: nil,
        api_id: nil,
        id: nil,
        root_resource_id: nil,
        openapi: nil,
        openapi_schema: nil,
        body: nil,
        body_s3_location: nil,
        description: nil,
        stage_name: nil,
        stage: nil,
        stage_variables: nil,
        tracing_enabled: nil,
        **
      )
        super()
        @name = name || :default
        @rest_api_id = rest_api_id || api_id || id
        @root_resource_id = root_resource_id
        @openapi = openapi || openapi_schema || body || body_s3_location
        @description = description
        raw_stage = stage_name.nil? ? stage : stage_name
        @stage_name = raw_stage.nil? ? Model::RestApi::DEFAULT_STAGE_NAME : raw_stage
        @stage_variables = stage_variables
        @tracing_enabled = tracing_enabled
        @methods = []
      end

      def rest_api_id(val)
        @rest_api_id = val
      end
      alias api_id rest_api_id
      alias id rest_api_id

      def root_resource_id(val)
        @root_resource_id = val
      end

      def openapi(schema = nil, **kwargs)
        @openapi = if schema.is_a?(Hash)
                     schema.merge(kwargs)
                   elsif kwargs.empty?
                     schema
                   else
                     kwargs
                   end
      end
      alias openapi_schema openapi
      alias body openapi
      alias body_s3_location openapi

      def description(desc)
        @description = desc
      end

      def stage_name(name)
        @stage_name = name
      end
      alias stage stage_name

      def stage_variables(vars)
        @stage_variables = vars
      end

      def tracing_enabled(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @tracing_enabled = flag
      end

      def get(path_or_opts = nil, **)
        add_method(:get, path_or_opts, **)
      end

      def post(path_or_opts = nil, **)
        add_method(:post, path_or_opts, **)
      end

      def put(path_or_opts = nil, **)
        add_method(:put, path_or_opts, **)
      end

      def patch(path_or_opts = nil, **)
        add_method(:patch, path_or_opts, **)
      end

      def delete(path_or_opts = nil, **)
        add_method(:delete, path_or_opts, **)
      end

      def head(path_or_opts = nil, **)
        add_method(:head, path_or_opts, **)
      end

      def options(path_or_opts = nil, **)
        add_method(:options, path_or_opts, **)
      end

      def any(path_or_opts = nil, **)
        add_method(:any, path_or_opts, **)
      end

      def route(method_or_route_key, path_or_opts = nil, **)
        resolved_method, resolved_path_or_opts = resolve_route_signature(method_or_route_key, path_or_opts)
        add_method(resolved_method, resolved_path_or_opts, **)
      end

      def method(http_method, path_or_opts = nil, **kwargs)
        return super(http_method) if path_or_opts.nil? && kwargs.empty?

        route(http_method, path_or_opts, **kwargs)
      end

      def build
        Model::RestApi.new(
          @name,
          rest_api_id: @rest_api_id,
          root_resource_id: @root_resource_id,
          openapi: @openapi,
          description: @description,
          stage_name: @stage_name,
          stage_variables: @stage_variables,
          tracing_enabled: @tracing_enabled,
          methods: @methods
        )
      end

      private

      def add_method(http_method, path_or_opts = nil, **kwargs)
        opts = kwargs.dup
        path = nil
        if path_or_opts.is_a?(Hash)
          opts.merge!(path_or_opts)
          path = opts[:path]
        elsif path_or_opts
          path = path_or_opts
        else
          path = opts[:path]
        end

        @methods << {
          method: http_method,
          path: path,
          resource_id: opts[:resource_id],
          to: opts[:to] || opts[:target] || opts[:function],
          authorization_type: opts[:authorization_type],
          authorizer_id: opts[:authorizer_id],
          api_key_required: opts[:api_key_required] || false
        }
      end

      def resolve_route_signature(method_or_route_key, path_or_opts)
        if path_or_opts.nil?
          str = method_or_route_key.to_s.strip
          parts = str.split(/\s+/, 2)
          return [parts[0], parts[1]] if parts.size == 2
        end

        [method_or_route_key, path_or_opts]
      end
    end
  end
end
