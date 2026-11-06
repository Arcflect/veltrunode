# frozen_string_literal: true

require_relative 'http_api'

module Veltrunode
  module Model
    # Lambda Function URL (AWS::Lambda::Url) の設定を表す値オブジェクト
    class FunctionUrl
      VALID_AUTH_TYPES = %w[NONE AWS_IAM].freeze
      DEFAULT_AUTH_TYPE = 'NONE'
      VALID_INVOKE_MODES = %w[BUFFERED RESPONSE_STREAM].freeze

      attr_reader :auth_type, :cors, :invoke_mode, :qualifier

      alias auth auth_type

      def self.from(val)
        return nil if val.nil? || val == false
        return val if val.is_a?(self)

        case val
        when true
          new
        when Symbol, String
          new(auth_type: val)
        when Hash
          sym = val.transform_keys(&:to_sym)
          return nil if sym[:enabled] == false

          sym.delete(:enabled)
          new(**sym)
        else
          raise ArgumentError, "Invalid function_url configuration: #{val.inspect}"
        end
      end

      def initialize(
        auth_type: nil,
        auth: nil,
        cors: nil,
        invoke_mode: nil,
        qualifier: nil
      )
        @auth_type = normalize_auth_type(auth_type || auth)
        @cors = HttpCors.from(cors)
        @invoke_mode = normalize_invoke_mode(invoke_mode)
        @qualifier = normalize_optional_string(qualifier)
        freeze
      end

      def public_access?
        @auth_type == 'NONE'
      end

      def iam_auth?
        @auth_type == 'AWS_IAM'
      end

      def cors?
        !@cors.nil?
      end

      def to_h
        {
          'auth_type' => @auth_type,
          'cors' => @cors&.to_h,
          'invoke_mode' => @invoke_mode,
          'qualifier' => @qualifier
        }.compact
      end

      private

      def normalize_auth_type(val)
        return DEFAULT_AUTH_TYPE if val.nil? || val.to_s.strip.empty?

        norm = val.to_s.strip.upcase
        norm = 'AWS_IAM' if norm == 'IAM'
        unless VALID_AUTH_TYPES.include?(norm)
          raise ArgumentError,
                "Invalid function_url auth_type '#{val}'. Valid auth types: #{VALID_AUTH_TYPES.join(', ')}"
        end

        norm.freeze
      end

      def normalize_invoke_mode(val)
        return nil if val.nil? || val.to_s.strip.empty?

        norm = val.to_s.strip.upcase
        unless VALID_INVOKE_MODES.include?(norm)
          raise ArgumentError,
                "Invalid function_url invoke_mode '#{val}'. Valid invoke modes: #{VALID_INVOKE_MODES.join(', ')}"
        end

        norm.freeze
      end

      def normalize_optional_string(val)
        return nil if val.nil?

        str = val.to_s.strip
        str.empty? ? nil : str.freeze
      end
    end
  end
end
