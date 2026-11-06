# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'http_api_builder'
require_relative '../model/function_url'

module Veltrunode
  module DSL
    # function_url ブロックを構築するビルダークラス
    class FunctionUrlBuilder < BaseBuilder
      def initialize(
        auth_type: nil,
        auth: nil,
        cors: nil,
        invoke_mode: nil,
        qualifier: nil,
        **
      )
        super()
        @auth_type = auth_type || auth
        @cors = Model::HttpCors.from(cors)
        @invoke_mode = invoke_mode
        @qualifier = qualifier
      end

      def auth_type(val)
        @auth_type = val
      end
      alias auth auth_type

      def invoke_mode(val)
        @invoke_mode = val
      end

      def qualifier(val)
        @qualifier = val
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

      def build
        Model::FunctionUrl.new(
          auth_type: @auth_type,
          cors: @cors,
          invoke_mode: @invoke_mode,
          qualifier: @qualifier
        )
      end
    end
  end
end
