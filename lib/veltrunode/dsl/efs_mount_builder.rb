# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'managed_access_point_builder'
require_relative '../model/efs_mount'

module Veltrunode
  module DSL
    class EfsMountBuilder < BaseBuilder
      def initialize(symbolic_name)
        super()
        @symbolic_name = symbolic_name.to_s
        @access_point_source = nil
        @managed_access_point = nil
        @local_path = nil
        @vpc_expectations = {}
        @posix_expectations = {}
        @diagnostic_policy = {}
      end

      def managed_access_point(
        file_system_id = nil,
        root_directory: nil,
        path: nil,
        posix_user: nil,
        uid: nil,
        gid: nil,
        secondary_gids: nil,
        creation_info: nil,
        tags: nil,
        &
      )
        builder = ManagedAccessPointBuilder.new(
          file_system_id,
          root_directory: root_directory,
          path: path,
          posix_user: posix_user,
          uid: uid,
          gid: gid,
          secondary_gids: secondary_gids,
          creation_info: creation_info,
          tags: tags
        )
        builder.instance_eval(&) if block_given?
        @managed_access_point = builder.build
        @access_point_source ||= @symbolic_name
        @local_path ||= builder.local_path_val if builder.local_path_val

        if @managed_access_point.uid && !@posix_expectations.key?(:uid)
          @posix_expectations[:uid] = @managed_access_point.uid
        end
        if @managed_access_point.gid && !@posix_expectations.key?(:gid)
          @posix_expectations[:gid] = @managed_access_point.gid
        end

        @managed_access_point
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
          managed_access_point: @managed_access_point,
          local_path: @local_path,
          vpc_expectations: @vpc_expectations,
          posix_expectations: @posix_expectations,
          diagnostic_policy: @diagnostic_policy
        )
      end
    end
  end
end
