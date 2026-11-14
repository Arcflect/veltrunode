# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/managed_access_point'

module Veltrunode
  module DSL
    class ManagedAccessPointBuilder < BaseBuilder
      # backup { ... } ブロック用ビルダ
      class BackupBlockBuilder < BaseBuilder
        attr_reader :config

        def initialize(initial = {})
          super()
          @config = initial.dup
        end

        def schedule(val)
          @config[:schedule] = val
        end
        alias schedule_expression schedule

        def retention_days(val)
          @config[:retention_days] = val
        end
        alias delete_after_days retention_days
        alias retention retention_days

        def cold_storage_after_days(val)
          @config[:cold_storage_after_days] = val
        end
        alias move_to_cold_storage_after_days cold_storage_after_days

        def vault_name(val)
          @config[:vault_name] = val
        end
        alias backup_vault_name vault_name

        def plan_name(val)
          @config[:plan_name] = val
        end
        alias backup_plan_name plan_name

        def rule_name(val)
          @config[:rule_name] = val
        end
      end

      def initialize(
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
        throughput_mode: nil,
        provisioned_throughput_in_mibps: nil,
        provisioned_throughput: nil,
        backup: nil,
        backup_policy: nil,
        backup_plan: nil,
        local_path: nil,
        tags: nil
      )
        super()
        @file_system_id = file_system_id
        @root_directory_path = path || root_directory
        @posix_user = posix_user ? posix_user.dup : {}
        @posix_user[:uid] = uid if uid
        @posix_user[:gid] = gid if gid
        @posix_user[:secondary_gids] = secondary_gids if secondary_gids
        @creation_info = creation_info&.dup
        @lifecycle_policies = {}
        merge_lifecycle_policies!(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        @throughput_mode = throughput_mode
        @provisioned_throughput_in_mibps = if provisioned_throughput_in_mibps.nil?
                                             provisioned_throughput
                                           else
                                             provisioned_throughput_in_mibps
                                           end
        @backup = nil
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        merge_backup!(raw_backup) unless raw_backup.nil?
        @tags = tags ? tags.dup : {}
        @local_path_val = local_path&.to_s
      end

      attr_reader :local_path_val

      def local_path(val = nil)
        return @local_path_val if val.nil?

        @local_path_val = val.to_s
      end

      def file_system_id(id = nil)
        return @file_system_id if id.nil?

        @file_system_id = id.to_s
      end
      alias fs_id file_system_id

      def root_directory(path_or_hash = nil, path: nil, creation_info: nil, owner_uid: nil, owner_gid: nil,
                         permissions: nil, &)
        if path_or_hash.is_a?(Hash)
          @root_directory_path = (path_or_hash[:path] || path_or_hash['path']).to_s
          ci = path_or_hash[:creation_info] || path_or_hash['creation_info']
          @creation_info = ci if ci
        elsif path_or_hash
          @root_directory_path = path_or_hash.to_s
        elsif path
          @root_directory_path = path.to_s
        end

        ci_hash = creation_info || {}
        ci_hash[:owner_uid] = owner_uid if owner_uid
        ci_hash[:owner_gid] = owner_gid if owner_gid
        ci_hash[:permissions] = permissions if permissions
        @creation_info = ci_hash unless ci_hash.empty?

        instance_eval(&) if block_given?
      end

      def path(val)
        @root_directory_path = val.to_s
      end

      def creation_info(owner_uid: nil, owner_gid: nil, permissions: nil)
        @creation_info ||= {}
        @creation_info[:owner_uid] = owner_uid if owner_uid
        @creation_info[:owner_gid] = owner_gid if owner_gid
        @creation_info[:permissions] = permissions if permissions
      end

      def posix_user(uid_or_hash = nil, uid: nil, gid: nil, secondary_gids: nil, &)
        if uid_or_hash.is_a?(Hash)
          @posix_user.merge!(uid_or_hash)
        elsif uid_or_hash
          @posix_user[:uid] = uid_or_hash
        end

        @posix_user[:uid] = uid if uid
        @posix_user[:gid] = gid if gid
        @posix_user[:secondary_gids] = secondary_gids if secondary_gids

        instance_eval(&) if block_given?
      end

      def uid(val)
        @posix_user[:uid] = val
      end

      def gid(val)
        @posix_user[:gid] = val
      end

      def secondary_gids(*gids)
        @posix_user[:secondary_gids] = gids.flatten
      end

      def tags(hash)
        @tags.merge!(hash)
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

      def throughput_mode(mode = nil, provisioned_throughput_in_mibps: nil, provisioned_throughput: nil)
        @throughput_mode = mode unless mode.nil?
        pt = provisioned_throughput_in_mibps.nil? ? provisioned_throughput : provisioned_throughput_in_mibps
        @provisioned_throughput_in_mibps = pt unless pt.nil?
      end

      def provisioned_throughput_in_mibps(val)
        @provisioned_throughput_in_mibps = val
      end
      alias provisioned_throughput provisioned_throughput_in_mibps

      def backup(
        val = :__unset__,
        schedule: nil,
        retention_days: nil,
        cold_storage_after_days: nil,
        vault_name: nil,
        plan_name: nil,
        rule_name: nil,
        &
      )
        merge_backup!(
          val,
          schedule: schedule,
          retention_days: retention_days,
          cold_storage_after_days: cold_storage_after_days,
          vault_name: vault_name,
          plan_name: plan_name,
          rule_name: rule_name,
          &
        )
      end
      alias backup_policy backup
      alias backup_plan backup

      def build
        posix = @posix_user.empty? ? nil : @posix_user
        lifecycle = @lifecycle_policies.empty? ? nil : @lifecycle_policies
        has_fs_config = !lifecycle.nil? || !@throughput_mode.nil? ||
                        !@provisioned_throughput_in_mibps.nil? || (!@backup.nil? && @backup != false)
        opts = {
          root_directory_path: @root_directory_path,
          posix_user: posix,
          creation_info: @creation_info,
          lifecycle_policies: lifecycle,
          throughput_mode: @throughput_mode,
          provisioned_throughput_in_mibps: @provisioned_throughput_in_mibps,
          backup: @backup,
          tags: @tags.empty? ? nil : @tags
        }
        opts[:file_system_id] = @file_system_id unless @file_system_id.nil? && has_fs_config
        Model::ManagedAccessPoint.new(**opts)
      end

      private

      def merge_backup!(
        val = :__unset__,
        schedule: nil,
        retention_days: nil,
        cold_storage_after_days: nil,
        vault_name: nil,
        plan_name: nil,
        rule_name: nil,
        &
      )
        if val == false
          @backup = false
          return
        end

        if val != :__unset__ && val != true && !val.is_a?(Hash) && !val.nil?
          @backup = val
          return
        end

        @backup = @backup.is_a?(Hash) ? @backup.dup : {}
        @backup.merge!(val) if val.is_a?(Hash)
        @backup[:schedule] = schedule if schedule
        @backup[:retention_days] = retention_days if retention_days
        @backup[:cold_storage_after_days] = cold_storage_after_days if cold_storage_after_days
        @backup[:vault_name] = vault_name if vault_name
        @backup[:plan_name] = plan_name if plan_name
        @backup[:rule_name] = rule_name if rule_name

        return unless block_given?

        block_builder = BackupBlockBuilder.new(@backup)
        block_builder.instance_eval(&)
        @backup = block_builder.config
      end

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
