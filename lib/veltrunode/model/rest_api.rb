# frozen_string_literal: true

module Veltrunode
  module Model
    # API Gateway REST API (v1) の個別メソッド定義を表す値オブジェクト
    class RestMethod
      SUPPORTED_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS ANY].freeze
      VALID_AUTHORIZATION_TYPES = %w[NONE AWS_IAM CUSTOM COGNITO_USER_POOLS].freeze
      DEFAULT_AUTHORIZATION_TYPE = 'NONE'

      attr_reader :method, :path, :resource_id, :target_function,
                  :authorization_type, :authorizer_id, :api_key_required

      alias http_method method
      alias to target_function
      alias target target_function
      alias function target_function

      # @param method [String, Symbol] HTTP メソッド (:get, :post, :put, :patch, :delete, :head, :options, :any)
      # @param path [String, nil] ルートパス (例: '/users', 省略可能)
      # @param resource_id [String, Symbol, Hash, DSL::Reference, nil] 既存 API Gateway リソース ID または参照
      # @param to [String, Symbol, nil] ターゲット Lambda 関数名
      # @param target [String, Symbol, nil] to のエイリアス
      # @param function [String, Symbol, nil] to のエイリアス
      # @param authorization_type [String, Symbol, nil] 認可種別 ('NONE', 'AWS_IAM', 'CUSTOM', 'COGNITO_USER_POOLS')
      # @param authorizer_id [String, Symbol, Hash, DSL::Reference, nil] カスタム/Cognito オーソライザー ID
      # @param api_key_required [Boolean] API キー（使用量プラン）を必須とするか
      def initialize(
        method:,
        path: nil,
        resource_id: nil,
        to: nil,
        target: nil,
        function: nil,
        authorization_type: nil,
        authorizer_id: nil,
        api_key_required: false
      )
        @method = normalize_method(method)
        @path = normalize_path(path)
        @resource_id = normalize_reference_or_string(resource_id, 'resource_id')
        @target_function = normalize_target(to || target || function)
        @authorization_type = normalize_authorization_type(authorization_type)
        @authorizer_id = normalize_reference_or_string(authorizer_id, 'authorizer_id')
        @api_key_required = api_key_required ? true : false
        freeze
      end

      def api_key_required?
        @api_key_required
      end

      def resource_identifier
        if @path && !@path.empty?
          cleaned = @path.gsub('$default', 'default').gsub(/[^a-zA-Z0-9]+/, '_').sub(/\A_+|_+\z/, '')
          return cleaned.empty? ? 'root' : cleaned
        end

        extract_ref_identifier(@resource_id) || 'root'
      end

      def to_h
        res_id_val = if !@resource_id.is_a?(Symbol) && @resource_id.respond_to?(:name)
                       @resource_id.name.to_s
                     else
                       @resource_id
                     end
        auth_id_val = if !@authorizer_id.is_a?(Symbol) && @authorizer_id.respond_to?(:name)
                        @authorizer_id.name.to_s
                      else
                        @authorizer_id
                      end

        {
          'method' => @method,
          'path' => @path,
          'resource_id' => res_id_val,
          'to' => @target_function,
          'authorization_type' => @authorization_type,
          'authorizer_id' => auth_id_val,
          'api_key_required' => @api_key_required
        }.compact
      end

      private

      def normalize_method(val)
        raise ArgumentError, 'HTTP method must be specified for REST API method.' if val.nil? || val.to_s.strip.empty?

        normalized = val.to_s.strip.upcase
        unless SUPPORTED_METHODS.include?(normalized)
          raise ArgumentError,
                "Unsupported HTTP method '#{val}'. Supported methods: #{SUPPORTED_METHODS.join(', ')}"
        end

        normalized.freeze
      end

      def normalize_path(val)
        return nil if val.nil?

        p_str = val.to_s.strip
        return nil if p_str.empty?

        raise ArgumentError, "REST API method path must start with '/', got '#{val}'." unless p_str.start_with?('/')

        p_str.freeze
      end

      def normalize_reference_or_string(val, field_name)
        return nil if val.nil?

        if (val.is_a?(Hash) && val.empty?) || (!val.is_a?(Hash) && val.to_s.strip.empty?)
          raise ArgumentError, "REST API #{field_name} cannot be empty."
        end

        if val.is_a?(Symbol) || val.respond_to?(:name)
          val
        elsif val.is_a?(Hash)
          deep_stringify_and_freeze(val)
        else
          val.to_s.strip.freeze
        end
      end

      def normalize_target(val)
        if val.nil? || val.to_s.strip.empty?
          raise ArgumentError, 'Target function (to:) must be specified for REST API method.'
        end

        val.to_s.strip.freeze
      end

      def normalize_authorization_type(val)
        return DEFAULT_AUTHORIZATION_TYPE if val.nil?

        normalized = val.to_s.strip.upcase
        unless VALID_AUTHORIZATION_TYPES.include?(normalized)
          raise ArgumentError,
                "Invalid authorization_type '#{val}'. " \
                "Valid types: #{VALID_AUTHORIZATION_TYPES.join(', ')}"
        end

        normalized.freeze
      end

      def extract_ref_identifier(val)
        return nil if val.nil?
        return val.to_s if val.is_a?(Symbol)
        return val.name.to_s if !val.is_a?(Symbol) && val.respond_to?(:name)

        if val.is_a?(Hash)
          ref_val = val['Ref'] || val[:Ref] || val[:ref] || val['ref']
          return ref_val.to_s if ref_val

          get_att = val['Fn::GetAtt'] || val[:'Fn::GetAtt']
          return Array(get_att).first.to_s if get_att

          return nil
        end

        val.to_s
      end

      def deep_stringify_and_freeze(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), memo|
            memo[k.to_s.freeze] = deep_stringify_and_freeze(v)
          end.freeze
        when Array
          obj.map { |v| deep_stringify_and_freeze(v) }.freeze
        when Symbol
          obj.to_s.freeze
        when String
          obj.dup.freeze
        else
          obj
        end
      end
    end

    # API Gateway REST API (v1) 定義を表すモデルクラス
    class RestApi
      DEFAULT_NAME = 'default'
      DEFAULT_STAGE_NAME = 'prod'

      attr_reader :name, :rest_api_id, :root_resource_id, :openapi,
                  :description, :stage_name, :stage_variables, :tracing_enabled, :methods

      alias api_id rest_api_id
      alias id rest_api_id
      alias openapi_schema openapi
      alias body openapi
      alias routes methods

      def initialize(
        name = DEFAULT_NAME,
        rest_api_id: nil,
        api_id: nil,
        id: nil,
        root_resource_id: nil,
        openapi: nil,
        openapi_schema: nil,
        body: nil,
        body_s3_location: nil,
        description: nil,
        stage_name: DEFAULT_STAGE_NAME,
        stage_variables: nil,
        tracing_enabled: nil,
        methods: [],
        routes: []
      )
        @name = normalize_name(name)
        @rest_api_id = normalize_ref_or_str(rest_api_id || api_id || id, 'rest_api_id')
        @root_resource_id = normalize_ref_or_str(root_resource_id, 'root_resource_id')
        @openapi = normalize_openapi(openapi || openapi_schema || body || body_s3_location)
        @description = normalize_optional_string(description)
        @stage_name = normalize_stage_name(stage_name)
        @stage_variables = normalize_stage_variables(stage_variables)
        @tracing_enabled = normalize_boolean(tracing_enabled)
        raw_methods = methods.nil? || methods.empty? ? routes : methods
        @methods = normalize_methods(raw_methods)
        validate_methods!
        freeze
      end

      def external_rest_api?
        !@rest_api_id.nil?
      end
      alias existing_rest_api? external_rest_api?

      def managed_rest_api?
        @rest_api_id.nil?
      end

      def openapi?
        !@openapi.nil?
      end

      def methods?
        !@methods.empty?
      end
      alias routes? methods?

      def deployment?
        !@stage_name.nil? && !@methods.empty?
      end

      def tracing_enabled?
        @tracing_enabled == true
      end

      def to_h
        api_id_val = if !@rest_api_id.is_a?(Symbol) && @rest_api_id.respond_to?(:name)
                       @rest_api_id.name.to_s
                     else
                       @rest_api_id
                     end
        root_res_val = if !@root_resource_id.is_a?(Symbol) && @root_resource_id.respond_to?(:name)
                         @root_resource_id.name.to_s
                       else
                         @root_resource_id
                       end

        {
          'name' => @name,
          'rest_api_id' => api_id_val,
          'root_resource_id' => root_res_val,
          'openapi' => @openapi,
          'description' => @description,
          'stage_name' => @stage_name,
          'stage_variables' => @stage_variables,
          'tracing_enabled' => @tracing_enabled,
          'methods' => @methods.map(&:to_h)
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
        return nil if val == false
        return DEFAULT_STAGE_NAME if val.nil? || val.to_s.strip.empty?

        val.to_s.strip.freeze
      end

      def normalize_stage_variables(vars)
        return nil if vars.nil?

        raise ArgumentError, "stage_variables must be a Hash, got #{vars.class}." unless vars.is_a?(Hash)
        return nil if vars.empty?

        vars.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = v.to_s.freeze
        end.freeze
      end

      def normalize_boolean(val)
        return nil if val.nil?

        val ? true : false
      end

      def normalize_ref_or_str(val, field_name)
        return nil if val.nil?

        if (val.is_a?(Hash) && val.empty?) || (!val.is_a?(Hash) && val.to_s.strip.empty?)
          raise ArgumentError, "REST API #{field_name} cannot be empty."
        end

        if val.is_a?(Symbol) || val.respond_to?(:name)
          val
        elsif val.is_a?(Hash)
          deep_stringify_and_freeze(val)
        else
          val.to_s.strip.freeze
        end
      end

      def normalize_openapi(val)
        return nil if val.nil?

        if val.is_a?(Hash)
          raise ArgumentError, 'OpenAPI schema hash cannot be empty.' if val.empty?

          deep_stringify_and_freeze(val)
        else
          str = val.to_s.strip
          raise ArgumentError, 'OpenAPI schema specification cannot be empty.' if str.empty?

          str.freeze
        end
      end

      def normalize_methods(raw_methods)
        Array(raw_methods).map do |m|
          if m.is_a?(RestMethod)
            m
          elsif m.is_a?(Hash)
            sym = m.transform_keys(&:to_sym)
            RestMethod.new(
              method: sym[:method] || sym[:http_method],
              path: sym[:path],
              resource_id: sym[:resource_id] || @root_resource_id,
              to: sym[:to] || sym[:target] || sym[:function],
              authorization_type: sym[:authorization_type],
              authorizer_id: sym[:authorizer_id],
              api_key_required: sym[:api_key_required] || false
            )
          else
            raise ArgumentError, "Invalid REST API method definition: #{m.inspect}"
          end
        end.freeze
      end

      def validate_methods!
        return unless external_rest_api?

        @methods.each do |m|
          next if m.resource_id || @root_resource_id

          raise ArgumentError,
                "resource_id must be specified for REST API method '#{m.method}' " \
                'when referencing an existing REST API without root_resource_id.'
        end
      end

      def deep_stringify_and_freeze(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), memo|
            memo[k.to_s.freeze] = deep_stringify_and_freeze(v)
          end.freeze
        when Array
          obj.map { |v| deep_stringify_and_freeze(v) }.freeze
        when Symbol
          obj.to_s.freeze
        when String
          obj.dup.freeze
        else
          obj
        end
      end
    end
  end
end
