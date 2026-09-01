# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/efs_mount'

module Veltrunode
  module DSL
    class EfsMountBuilder < BaseBuilder
      def initialize(symbolic_name)
        super()
        @symbolic_name = symbolic_name.to_s
        @access_point_source = nil
        @local_path = nil
        @vpc_expectations = {}
        @posix_expectations = {}
        @diagnostic_policy = {}
      end

      def existing_access_point(arn: nil)
        @access_point_source = arn if arn
      end

      def arn(val)
        @access_point_source = val
      end

      def access_point_source(val)
        @access_point_source = val
      end

      def local_path(path)
        @local_path = path.to_s
      end

      def expect_posix(uid: nil, gid: nil)
        @posix_expectations[:uid] = uid if uid
        @posix_expectations[:gid] = gid if gid
      end

      def expect_vpc(security_group_id: nil, subnet_ids: nil)
        @vpc_expectations[:security_group_id] = security_group_id if security_group_id
        @vpc_expectations[:subnet_ids] = subnet_ids if subnet_ids
      end

      def diagnostic_policy(hash)
        @diagnostic_policy = hash
      end

      def build
        Model::EfsMount.new(
          symbolic_name: @symbolic_name,
          access_point_source: @access_point_source || @symbolic_name,
          local_path: @local_path,
          vpc_expectations: @vpc_expectations,
          posix_expectations: @posix_expectations,
          diagnostic_policy: @diagnostic_policy
        )
      end
    end
  end
end
