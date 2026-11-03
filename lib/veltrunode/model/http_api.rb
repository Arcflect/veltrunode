# frozen_string_literal: true

module Veltrunode
  module Model
    # API Gateway HTTP API (v2) の個別ルート定義を表す値オブジェクト
    class HttpRoute
      SUPPORTED_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS ANY].freeze
      VALID_PAYLOAD_FORMAT_VERSIONS = %w[1.0 2.0].freeze
      DEFAULT_PAYLOAD_FORMAT_VERSION = '2.0'

      attr_reader :method, :path, :target_function, :payload_format_version

      alias http_method method
      alias to target_function
      alias target target_function
      alias function target_function

      # @param method [String, Symbol] HTTP メソッド (:get, :post, :put, :patch, :delete, :head, :options, :any)
      # @param path [String] ルートパス (例: '/users', '/users/{id}', '$default')
      # @param to [String, Symbol, nil] ターゲット Lambda 関数名
      # @param target [String, Symbol, nil] to のエイリアス
      # @param function [String, Symbol, nil] to のエイリアス
      # @param payload_format_version [String, nil] ペイロードフォーマットバージョン ('2.0' または '1.0')
      def initialize(method:, path:, to: nil, target: nil, function: nil, payload_format_version: nil)
        @method = normalize_method(method)
        @path = normalize_path(path)
        @target_function = normalize_target(to || target || function)
        @payload_format_version = normalize_payload_format_version(payload_format_version)
        freeze
      end

      def route_key
        return '$default' if @method == 'ANY' && @path == '$default'

        "#{@method} #{@path}"
      end

      def to_h
        {
          'method' => @method,
          'path' => @path,
          'to' => @target_function,
          'route_key' => route_key,
          'payload_format_version' => @payload_format_version
        }
      end

      private

      def normalize_method(val)
        raise ArgumentError, 'HTTP method must be specified for HTTP API route.' if val.nil? || val.to_s.strip.empty?

        normalized = val.to_s.strip.upcase
        unless SUPPORTED_METHODS.include?(normalized)
          raise ArgumentError,
                "Unsupported HTTP method '#{val}'. Supported methods: #{SUPPORTED_METHODS.join(', ')}"
        end

        normalized.freeze
      end

      def normalize_path(val)
        raise ArgumentError, 'Path must be specified for HTTP API route.' if val.nil? || val.to_s.strip.empty?

        p_str = val.to_s.strip
        unless p_str.start_with?('/') || p_str == '$default'
          raise ArgumentError, "HTTP API route path must start with '/', got '#{val}'."
        end

        p_str.freeze
      end

      def normalize_target(val)
        if val.nil? || val.to_s.strip.empty?
          raise ArgumentError, 'Target function (to:) must be specified for HTTP API route.'
        end

        val.to_s.strip.freeze
      end

      def normalize_payload_format_version(val)
        return DEFAULT_PAYLOAD_FORMAT_VERSION if val.nil?

        ver = val.to_s.strip
        unless VALID_PAYLOAD_FORMAT_VERSIONS.include?(ver)
          raise ArgumentError,
                "Invalid payload_format_version '#{val}'. " \
                "Valid versions: #{VALID_PAYLOAD_FORMAT_VERSIONS.join(', ')}"
        end

        ver.freeze
      end
    end

    # API Gateway HTTP API (v2) の CORS 設定を表す値オブジェクト
    class HttpCors
      DEFAULT_ALLOW_ORIGINS = ['*'].freeze
      DEFAULT_ALLOW_METHODS = ['*'].freeze
      DEFAULT_ALLOW_HEADERS = ['*'].freeze

      attr_reader :allow_origins, :allow_methods, :allow_headers,
                  :expose_headers, :max_age, :allow_credentials

      alias origins allow_origins
      alias methods allow_methods
      alias headers allow_headers
      alias credentials allow_credentials

      def self.from(val)
        return nil if val.nil? || val == false
        return val if val.is_a?(self)

        if val == true
          new(
            allow_origins: DEFAULT_ALLOW_ORIGINS,
            allow_methods: DEFAULT_ALLOW_METHODS,
            allow_headers: DEFAULT_ALLOW_HEADERS
          )
        elsif val.is_a?(Hash)
          symbolized = val.transform_keys(&:to_sym)
          new(**symbolized)
        else
          raise ArgumentError, "Invalid CORS configuration: #{val.inspect}"
        end
      end

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
        credentials: nil
      )
        raw_origins = allow_origins.nil? ? origins : allow_origins
        raw_methods = allow_methods.nil? ? methods : allow_methods
        raw_headers = allow_headers.nil? ? headers : allow_headers
        raw_credentials = allow_credentials.nil? ? credentials : allow_credentials

        @allow_origins = normalize_string_list(raw_origins)
        @allow_methods = normalize_method_list(raw_methods)
        @allow_headers = normalize_string_list(raw_headers)
        @expose_headers = normalize_string_list(expose_headers)
        @max_age = normalize_max_age(max_age)
        @allow_credentials = normalize_boolean(raw_credentials)
        freeze
      end

      def allow_credentials?
        @allow_credentials == true
      end

      def to_cfn_properties
        props = {}
        props['AllowOrigins'] = @allow_origins if @allow_origins
        props['AllowMethods'] = @allow_methods if @allow_methods
        props['AllowHeaders'] = @allow_headers if @allow_headers
        props['ExposeHeaders'] = @expose_headers if @expose_headers
        props['MaxAge'] = @max_age unless @max_age.nil?
        props['AllowCredentials'] = @allow_credentials unless @allow_credentials.nil?
        props
      end

      def to_h
        {
          'allow_origins' => @allow_origins,
          'allow_methods' => @allow_methods,
          'allow_headers' => @allow_headers,
          'expose_headers' => @expose_headers,
          'max_age' => @max_age,
          'allow_credentials' => @allow_credentials
        }.compact
      end

      private

      def normalize_string_list(val)
        return nil if val.nil?

        list = Array(val).map { |v| v.to_s.strip }.reject(&:empty?)
        return nil if list.empty?

        list.map(&:freeze).freeze
      end

      def normalize_method_list(val)
        return nil if val.nil?

        list = Array(val).map { |v| v.to_s.strip.upcase }.reject(&:empty?)
        return nil if list.empty?

        list.map(&:freeze).freeze
      end

      def normalize_max_age(val)
        return nil if val.nil?

        int_val = val.to_i
        raise ArgumentError, "CORS max_age must be >= 0, got #{val}." if int_val.negative?

        int_val
      end

      def normalize_boolean(val)
        return nil if val.nil?

        val ? true : false
      end
    end

    # API Gateway HTTP API (v2) 定義を表すモデルクラス
    class HttpApi
      DEFAULT_NAME = 'default'
      DEFAULT_STAGE_NAME = '$default'
      DEFAULT_PAYLOAD_FORMAT_VERSION = '2.0'

      attr_reader :name, :description, :stage_name, :auto_deploy, :cors, :routes, :payload_format_version

      def initialize(
        name = DEFAULT_NAME,
        description: nil,
        stage_name: DEFAULT_STAGE_NAME,
        auto_deploy: true,
        cors: nil,
        routes: [],
        payload_format_version: DEFAULT_PAYLOAD_FORMAT_VERSION
      )
        @name = normalize_name(name)
        @description = normalize_optional_string(description)
        @stage_name = normalize_stage_name(stage_name)
        @auto_deploy = auto_deploy.nil? || auto_deploy ? true : false
        @cors = HttpCors.from(cors)
        @payload_format_version = (payload_format_version || DEFAULT_PAYLOAD_FORMAT_VERSION).to_s.strip.freeze
        @routes = normalize_routes(routes)
        freeze
      end

      def cors?
        !@cors.nil?
      end

      def routes?
        !@routes.empty?
      end

      def auto_deploy?
        @auto_deploy
      end

      def default_stage?
        @stage_name == DEFAULT_STAGE_NAME
      end

      def to_h
        {
          'name' => @name,
          'description' => @description,
          'stage_name' => @stage_name,
          'auto_deploy' => @auto_deploy,
          'payload_format_version' => @payload_format_version,
          'cors' => @cors&.to_h,
          'routes' => @routes.map(&:to_h)
        }.compact
      end

      private

      def normalize_name(val)
        return DEFAULT_NAME if val.nil? || val.to_s.strip.empty?

        val.to_s.strip.freeze
      end

      def normalize_optional_string(val)
        return nil if val.nil?

        str = val.to_s.strip
        str.empty? ? nil : str.freeze
      end

      def normalize_stage_name(val)
        return DEFAULT_STAGE_NAME if val.nil? || val.to_s.strip.empty?

        val.to_s.strip.freeze
      end

      def normalize_routes(raw_routes)
        Array(raw_routes).map do |r|
          if r.is_a?(HttpRoute)
            r
          elsif r.is_a?(Hash)
            sym = r.transform_keys(&:to_sym)
            HttpRoute.new(
              method: sym[:method] || sym[:http_method],
              path: sym[:path],
              to: sym[:to] || sym[:target] || sym[:function],
              payload_format_version: sym[:payload_format_version] || @payload_format_version
            )
          else
            raise ArgumentError, "Invalid route definition: #{r.inspect}"
          end
        end.freeze
      end
    end
  end
end
