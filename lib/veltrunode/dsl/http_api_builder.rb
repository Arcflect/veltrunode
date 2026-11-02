# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/http_api'

module Veltrunode
  module DSL
    # http_api ブロック内の cors ブロックを構築するビルダークラス
    class HttpCorsBuilder < BaseBuilder
      def initialize(
        allow_origins: nil,
        origins: nil,
        allow_methods: nil,
        methods: nil,
        allow_headers: nil,
        headers: nil,
        expose_headers: nil,
        max_age: nil,
        allow_credentials: nil,
        credentials: nil,
        **
      )
        super()
        @allow_origins = allow_origins || origins
        @allow_methods = allow_methods || methods
        @allow_headers = allow_headers || headers
        @expose_headers = expose_headers
        @max_age = max_age
        @allow_credentials = allow_credentials.nil? ? credentials : allow_credentials
      end

      def allow_origins(*vals)
        @allow_origins = vals.flatten
      end
      alias origins allow_origins

      def allow_methods(*vals)
        @allow_methods = vals.flatten
      end

      def methods(*vals)
        return super() if vals.empty?

        allow_methods(*vals)
      end

      def allow_headers(*vals)
        @allow_headers = vals.flatten
      end
      alias headers allow_headers

      def expose_headers(*vals)
        @expose_headers = vals.flatten
      end

      def max_age(seconds)
        @max_age = seconds
      end

      def allow_credentials(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @allow_credentials = flag
      end
      alias credentials allow_credentials

      def build
        Model::HttpCors.new(
          allow_origins: @allow_origins,
          allow_methods: @allow_methods,
          allow_headers: @allow_headers,
          expose_headers: @expose_headers,
          max_age: @max_age,
          allow_credentials: @allow_credentials
        )
      end
    end

    # http_api ブロックを構築するビルダークラス
    class HttpApiBuilder < BaseBuilder
      def initialize(
        name = :default,
        description: nil,
        stage_name: nil,
        stage: nil,
        auto_deploy: true,
        cors: nil,
        payload_format_version: nil,
        **
      )
        super()
        @name = name || :default
        @description = description
        @stage_name = stage_name || stage || Model::HttpApi::DEFAULT_STAGE_NAME
        @auto_deploy = auto_deploy
        @cors = Model::HttpCors.from(cors)
        @payload_format_version = payload_format_version || Model::HttpApi::DEFAULT_PAYLOAD_FORMAT_VERSION
        @routes = []
      end

      def description(desc)
        @description = desc
      end

      def stage_name(name)
        @stage_name = name
      end
      alias stage stage_name

      def auto_deploy(flag = true) # rubocop:disable Style/OptionalBooleanParameter
        @auto_deploy = flag
      end

      def payload_format_version(ver)
        @payload_format_version = ver
      end

      def cors(arg = nil, **kwargs, &)
        if block_given?
          init_opts = arg.is_a?(Hash) ? arg.merge(kwargs) : kwargs
          builder = HttpCorsBuilder.new(**init_opts)
          builder.instance_eval(&)
          @cors = builder.build
        elsif arg == false
          @cors = nil
        elsif arg == true && kwargs.empty?
          @cors = Model::HttpCors.from(true)
        elsif arg.is_a?(Hash)
          @cors = Model::HttpCors.from(arg.merge(kwargs))
        elsif !kwargs.empty?
          @cors = Model::HttpCors.from(kwargs)
        else
          @cors = Model::HttpCors.from(arg.nil? || arg)
        end
      end

      def get(path, to: nil, target: nil, function: nil, **)
        add_route(:get, path, to: to || target || function, **)
      end

      def post(path, to: nil, target: nil, function: nil, **)
        add_route(:post, path, to: to || target || function, **)
      end

      def put(path, to: nil, target: nil, function: nil, **)
        add_route(:put, path, to: to || target || function, **)
      end

      def patch(path, to: nil, target: nil, function: nil, **)
        add_route(:patch, path, to: to || target || function, **)
      end

      def delete(path, to: nil, target: nil, function: nil, **)
        add_route(:delete, path, to: to || target || function, **)
      end

      def head(path, to: nil, target: nil, function: nil, **)
        add_route(:head, path, to: to || target || function, **)
      end

      def options(path, to: nil, target: nil, function: nil, **)
        add_route(:options, path, to: to || target || function, **)
      end

      def any(path = '$default', to: nil, target: nil, function: nil, **)
        add_route(:any, path, to: to || target || function, **)
      end

      def route(method_or_route_key, path = nil, to: nil, target: nil, function: nil, **)
        resolved_method, resolved_path = resolve_route_signature(method_or_route_key, path)
        add_route(resolved_method, resolved_path, to: to || target || function, **)
      end

      def build
        Model::HttpApi.new(
          @name,
          description: @description,
          stage_name: @stage_name,
          auto_deploy: @auto_deploy,
          cors: @cors,
          routes: @routes,
          payload_format_version: @payload_format_version
        )
      end

      private

      def add_route(method, path, to:, payload_format_version: nil, **)
        @routes << Model::HttpRoute.new(
          method: method,
          path: path,
          to: to,
          payload_format_version: payload_format_version || @payload_format_version
        )
      end

      def resolve_route_signature(method_or_route_key, path)
        if path.nil?
          str = method_or_route_key.to_s.strip
          return [:any, '$default'] if str == '$default'

          parts = str.split(/\s+/, 2)
          return [parts[0], parts[1]] if parts.size == 2
        end

        [method_or_route_key, path]
      end
    end
  end
end
