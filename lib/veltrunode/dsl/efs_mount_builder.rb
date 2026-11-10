# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'managed_access_point_builder'
require_relative 'security_group_helper_builder'
require_relative '../model/efs_mount'

module Veltrunode
  module DSL
    class EfsMountBuilder < BaseBuilder
      def initialize(
        symbolic_name,
        local_path: nil,
        lifecycle_policies: nil,
        lifecycle_policy: nil,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil
      )
        super()
        @symbolic_name = symbolic_name.to_s
        @access_point_source = nil
        @managed_access_point = nil
        @security_group_helper = nil
        @local_path = local_path&.to_s
        @lifecycle_policies = {}
        merge_lifecycle_policies!(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
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
        lifecycle_policies: nil,
        lifecycle_policy: nil,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil,
        local_path: nil,
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
          lifecycle_policies: lifecycle_policies || lifecycle_policy ||
                              (@lifecycle_policies.empty? ? nil : @lifecycle_policies),
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class,
          local_path: local_path,
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

      def lifecycle_policies(
        policies = nil,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil,
        &
      )
        merge_lifecycle_policies!(
          policies,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        instance_eval(&) if block_given?
      end
      alias lifecycle_policy lifecycle_policies

      def transition_to_ia(val)
        @lifecycle_policies[:transition_to_ia] = val
      end

      def transition_to_archive(val)
        @lifecycle_policies[:transition_to_archive] = val
      end

      def transition_to_primary_storage_class(val)
        @lifecycle_policies[:transition_to_primary_storage_class] = val
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

      def security_group_helper(name = nil, vpc_id: nil, **, &)
        builder = if name.is_a?(Hash)
                    opts = name
                    target_name = @symbolic_name
                    target_vpc_id = opts[:vpc_id] || opts['vpc_id']
                    extra_opts = opts.reject { |k, _| k.to_s == 'vpc_id' }
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: target_vpc_id, **extra_opts)
                  else
                    target_name = name || @symbolic_name
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: vpc_id, **)
                  end
        builder.instance_eval(&) if block_given?
        @security_group_helper = builder.build
        @security_group_helper
      end
      alias efs_security_groups security_group_helper
      alias efs_security_group security_group_helper

      def build
        lifecycle = @lifecycle_policies.empty? ? nil : @lifecycle_policies
        resolved_local_path = @local_path || (@managed_access_point || lifecycle ? "/mnt/#{@symbolic_name}" : nil)
        Model::EfsMount.new(
          symbolic_name: @symbolic_name,
          access_point_source: @access_point_source || @symbolic_name,
          managed_access_point: @managed_access_point,
          security_group_helper: @security_group_helper,
          lifecycle_policies: lifecycle,
          local_path: resolved_local_path,
          vpc_expectations: @vpc_expectations,
          posix_expectations: @posix_expectations,
          diagnostic_policy: @diagnostic_policy
        )
      end

      private

      def merge_lifecycle_policies!(
        policies,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil
      )
        if policies.is_a?(Array)
          policies.each { |item| merge_lifecycle_policies!(item) }
        elsif policies.is_a?(Hash)
          ia = policies[:transition_to_ia] || policies['transition_to_ia'] ||
               policies[:TransitionToIA] || policies['TransitionToIA']
          arch = policies[:transition_to_archive] || policies['transition_to_archive'] ||
                 policies[:TransitionToArchive] || policies['TransitionToArchive']
          prim = policies[:transition_to_primary_storage_class] || policies['transition_to_primary_storage_class'] ||
                 policies[:TransitionToPrimaryStorageClass] || policies['TransitionToPrimaryStorageClass']
          @lifecycle_policies[:transition_to_ia] = ia if ia
          @lifecycle_policies[:transition_to_archive] = arch if arch
          @lifecycle_policies[:transition_to_primary_storage_class] = prim if prim
        end

        @lifecycle_policies[:transition_to_ia] = transition_to_ia if transition_to_ia
        @lifecycle_policies[:transition_to_archive] = transition_to_archive if transition_to_archive
        return unless transition_to_primary_storage_class

        @lifecycle_policies[:transition_to_primary_storage_class] = transition_to_primary_storage_class
      end
    end
  end
end
