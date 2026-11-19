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

      # alarms { ... } ブロック用ビルダ
      class AlarmsBlockBuilder < BaseBuilder
        attr_reader :config

        def initialize(initial = {})
          super()
          @config = initial.dup
        end

        def burst_credit_balance(val = nil, **kwargs)
          @config[:burst_credit_balance] = if val.is_a?(Hash)
                                             val.merge(kwargs)
                                           elsif kwargs.empty?
                                             val.nil? || val
                                           elsif val.nil?
                                             kwargs
                                           else
                                             kwargs.merge(threshold: val)
                                           end
        end
        alias burst_credit_balance_threshold burst_credit_balance
        alias burst_credit_threshold burst_credit_balance

        def percent_io_limit(val = nil, **kwargs)
          @config[:percent_io_limit] = if val.is_a?(Hash)
                                         val.merge(kwargs)
                                       elsif kwargs.empty?
                                         val.nil? || val
                                       elsif val.nil?
                                         kwargs
                                       else
                                         kwargs.merge(threshold: val)
                                       end
        end
        alias percent_io_limit_threshold percent_io_limit
        alias io_limit_threshold percent_io_limit

        def topic(val)
          @config[:topic] = val
        end
        alias alarm_topic topic

        def alarm_actions(*actions)
          @config[:alarm_actions] = actions.flatten
        end

        def ok_actions(*actions)
          @config[:ok_actions] = actions.flatten
        end

        def period(val)
          @config[:period] = val
        end

        def evaluation_periods(val)
          @config[:evaluation_periods] = val
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
        encrypted: nil,
        kms_key_id: nil,
        kms_key: nil,
        kms_key_arn: nil,
        backup: nil,
        backup_policy: nil,
        backup_plan: nil,
        alarms: nil,
        efs_alarms: nil,
        burst_credit_balance: nil,
        burst_credit_balance_threshold: nil,
        burst_credit_threshold: nil,
        percent_io_limit: nil,
        percent_io_limit_threshold: nil,
        io_limit_threshold: nil,
        alarm_topic: nil,
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
        @encrypted = encrypted
        @kms_key_id = kms_key_id || kms_key || kms_key_arn
        @backup = nil
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        merge_backup!(raw_backup) unless raw_backup.nil?
        @alarms = nil
        raw_alarms = alarms.nil? ? efs_alarms : alarms
        has_alarm_kwargs = !burst_credit_balance.nil? || !burst_credit_balance_threshold.nil? ||
                           !burst_credit_threshold.nil? || !percent_io_limit.nil? ||
                           !percent_io_limit_threshold.nil? || !io_limit_threshold.nil? ||
                           !alarm_topic.nil?
        if !raw_alarms.nil? || has_alarm_kwargs
          merge_alarms!(
            raw_alarms.nil? ? :__unset__ : raw_alarms,
            burst_credit_balance: burst_credit_balance || burst_credit_balance_threshold || burst_credit_threshold,
            percent_io_limit: percent_io_limit || percent_io_limit_threshold || io_limit_threshold,
            topic: alarm_topic
          )
        end
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

      def encrypted(val = true, kms_key_id: nil, kms_key: nil, kms_key_arn: nil) # rubocop:disable Style/OptionalBooleanParameter
        @encrypted = val
        kms = kms_key_id || kms_key || kms_key_arn
        @kms_key_id = kms unless kms.nil?
      end
      alias encryption encrypted

      def kms_key_id(val)
        @kms_key_id = val
      end
      alias kms_key kms_key_id
      alias kms_key_arn kms_key_id

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

      def alarms(
        val = :__unset__,
        burst_credit_balance: nil,
        burst_credit_balance_threshold: nil,
        burst_credit_threshold: nil,
        percent_io_limit: nil,
        percent_io_limit_threshold: nil,
        io_limit_threshold: nil,
        topic: nil,
        alarm_actions: nil,
        ok_actions: nil,
        period: nil,
        evaluation_periods: nil,
        &
      )
        merge_alarms!(
          val,
          burst_credit_balance: burst_credit_balance || burst_credit_balance_threshold || burst_credit_threshold,
          percent_io_limit: percent_io_limit || percent_io_limit_threshold || io_limit_threshold,
          topic: topic,
          alarm_actions: alarm_actions,
          ok_actions: ok_actions,
          period: period,
          evaluation_periods: evaluation_periods,
          &
        )
      end
      alias efs_alarms alarms
      alias efs_alarm_helper alarms

      def burst_credit_balance(val)
        merge_alarms!(burst_credit_balance: val)
      end
      alias burst_credit_balance_threshold burst_credit_balance
      alias burst_credit_threshold burst_credit_balance

      def percent_io_limit(val)
        merge_alarms!(percent_io_limit: val)
      end
      alias percent_io_limit_threshold percent_io_limit
      alias io_limit_threshold percent_io_limit

      def alarm_topic(val)
        merge_alarms!(topic: val)
      end

      def build
        posix = @posix_user.empty? ? nil : @posix_user
        lifecycle = @lifecycle_policies.empty? ? nil : @lifecycle_policies
        has_fs_config = !lifecycle.nil? || !@throughput_mode.nil? ||
                        !@provisioned_throughput_in_mibps.nil? ||
                        !@encrypted.nil? || !@kms_key_id.nil? ||
                        (!@backup.nil? && @backup != false) ||
                        (!@alarms.nil? && @alarms != false)
        opts = {
          root_directory_path: @root_directory_path,
          posix_user: posix,
          creation_info: @creation_info,
          lifecycle_policies: lifecycle,
          throughput_mode: @throughput_mode,
          provisioned_throughput_in_mibps: @provisioned_throughput_in_mibps,
          encrypted: @encrypted,
          kms_key_id: @kms_key_id,
          backup: @backup,
          alarms: @alarms,
          tags: @tags.empty? ? nil : @tags
        }
        opts[:file_system_id] = @file_system_id unless @file_system_id.nil? && has_fs_config
        Model::ManagedAccessPoint.new(**opts)
      end

      private

      def merge_alarms!(
        val = :__unset__,
        burst_credit_balance: nil,
        percent_io_limit: nil,
        topic: nil,
        alarm_actions: nil,
        ok_actions: nil,
        period: nil,
        evaluation_periods: nil,
        &
      )
        if val == false
          @alarms = false
          return
        end

        if val != :__unset__ && val != true && !val.is_a?(Hash) && !val.nil?
          @alarms = val
          return
        end

        @alarms = @alarms.is_a?(Hash) ? @alarms.dup : {}
        @alarms.merge!(val) if val.is_a?(Hash)
        @alarms[:burst_credit_balance] = burst_credit_balance unless burst_credit_balance.nil?
        @alarms[:percent_io_limit] = percent_io_limit unless percent_io_limit.nil?
        @alarms[:topic] = topic if topic
        @alarms[:alarm_actions] = alarm_actions if alarm_actions
        @alarms[:ok_actions] = ok_actions if ok_actions
        @alarms[:period] = period if period
        @alarms[:evaluation_periods] = evaluation_periods if evaluation_periods

        return unless block_given?

        block_builder = AlarmsBlockBuilder.new(@alarms)
        block_builder.instance_eval(&)
        @alarms = block_builder.config
      end

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
