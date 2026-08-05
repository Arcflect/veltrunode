# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/capability'

module Veltrunode
  module DSL
    class PermitBuilder < BaseBuilder
      attr_reader :capabilities

      def initialize
        super
        @capabilities = []
      end

      def read_from_s3(bucket:, prefix: nil)
        @capabilities << Model::Capability.new(
          type: :read_from_s3,
          params: { bucket: bucket, prefix: prefix }.compact
        )
      end

      def write_to_s3(bucket:, prefix: nil)
        @capabilities << Model::Capability.new(
          type: :write_to_s3,
          params: { bucket: bucket, prefix: prefix }.compact
        )
      end

      def read_parameter(name: nil, path: nil)
        param_name = name || path
        @capabilities << Model::Capability.new(
          type: :read_parameter,
          params: { name: param_name }.compact
        )
      end

      def allow(actions:, resources: ['*'])
        @capabilities << Model::Capability.new(
          type: :custom,
          params: { actions: actions, resources: resources }.compact
        )
      end

      def custom(actions:, resources: ['*'])
        allow(actions: actions, resources: resources)
      end
    end
  end
end
