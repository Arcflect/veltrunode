# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'managed_access_point_builder'
require_relative 'security_group_helper_builder'
require_relative '../model/efs_mount'

module Veltrunode
  module DSL
    class EfsMountBuilder < BaseBuilder
      attr_reader :symbolic_name

      def initialize(
        symbolic_name,
        local_path: nil,
        arn: nil,
        access_point_source: nil,
        vpc_id: nil,
        vpc: nil,
        subnet_ids: nil,
        subnets: nil,
        security_group_ids: nil,
        security_groups: nil,
        deletion_policy: nil,
        update_replace_policy: nil,
        deletion_protection: nil,
        root_directory: nil,
        path: nil,
        posix_user: nil,
        uid: nil,
        gid: nil,
        secondary_gids: nil,
        creation_info: nil,
        tags: nil,
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
        alarm_topic: nil
      )
        super()
        @symbolic_name = symbolic_name.to_s
        @access_point_source = access_point_source || arn
        @managed_access_point = nil
        @managed_file_system_enabled = false
        @security_group_helper = nil
        @local_path = local_path&.to_s
        @vpc_id = nil
        @subnet_ids = nil
        @security_group_ids = nil
        vpc_id(
          vpc_id || vpc,
          subnet_ids: subnet_ids,
          subnets: subnets,
          security_group_ids: security_group_ids,
          security_groups: security_groups
        )
        @deletion_policy = deletion_policy
        @update_replace_policy = update_replace_policy
        @deletion_protection = deletion_protection
        @ap_options = {}
        apply_direct_ap_options(
          root_directory: root_directory,
          path: path,
          posix_user: posix_user,
          uid: uid,
          gid: gid,
          secondary_gids: secondary_gids,
          creation_info: creation_info,
          tags: tags
        )
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
        tags: nil,
        &
      )
        resolved_pt = if !provisioned_throughput_in_mibps.nil?
                        provisioned_throughput_in_mibps
                      elsif !provisioned_throughput.nil?
                        provisioned_throughput
                      else
                        @provisioned_throughput_in_mibps
                      end
        resolved_enc = encrypted.nil? ? @encrypted : encrypted
        resolved_kms = if !kms_key_id.nil?
                         kms_key_id
                       elsif !kms_key.nil?
                         kms_key
                       elsif !kms_key_arn.nil?
                         kms_key_arn
                       else
                         @kms_key_id
                       end
        resolved_backup = if !backup.nil?
                            backup
                          elsif !backup_policy.nil?
                            backup_policy
                          elsif !backup_plan.nil?
                            backup_plan
                          else
                            @backup
                          end
        resolved_alarms = if !alarms.nil?
                            alarms
                          elsif !efs_alarms.nil?
                            efs_alarms
                          else
                            @alarms
                          end
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
          throughput_mode: throughput_mode || @throughput_mode,
          provisioned_throughput_in_mibps: resolved_pt,
          encrypted: resolved_enc,
          kms_key_id: resolved_kms,
          backup: resolved_backup,
          alarms: resolved_alarms,
          burst_credit_balance: burst_credit_balance,
          burst_credit_balance_threshold: burst_credit_balance_threshold,
          burst_credit_threshold: burst_credit_threshold,
          percent_io_limit: percent_io_limit,
          percent_io_limit_threshold: percent_io_limit_threshold,
          io_limit_threshold: io_limit_threshold,
          alarm_topic: alarm_topic,
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
      alias access_point managed_access_point

      def managed_file_system(
        vpc_id: nil,
        vpc: nil,
        subnet_ids: nil,
        subnets: nil,
        security_group_ids: nil,
        security_groups: nil,
        deletion_policy: nil,
        update_replace_policy: nil,
        deletion_protection: nil,
        local_path: nil,
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
        tags: nil,
        &
      )
        @managed_file_system_enabled = true
        self.vpc_id(
          vpc_id || vpc,
          subnet_ids: subnet_ids,
          subnets: subnets,
          security_group_ids: security_group_ids,
          security_groups: security_groups
        )
        @deletion_policy = deletion_policy unless deletion_policy.nil?
        @update_replace_policy = update_replace_policy unless update_replace_policy.nil?
        @deletion_protection = deletion_protection unless deletion_protection.nil?
        @local_path = local_path.to_s if local_path
        apply_direct_ap_options(
          root_directory: root_directory,
          path: path,
          posix_user: posix_user,
          uid: uid,
          gid: gid,
          secondary_gids: secondary_gids,
          creation_info: creation_info,
          tags: tags
        )
        merge_lifecycle_policies!(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        @throughput_mode = throughput_mode unless throughput_mode.nil?
        pt = provisioned_throughput_in_mibps.nil? ? provisioned_throughput : provisioned_throughput_in_mibps
        @provisioned_throughput_in_mibps = pt unless pt.nil?
        @encrypted = encrypted unless encrypted.nil?
        kms = kms_key_id || kms_key || kms_key_arn
        @kms_key_id = kms unless kms.nil?
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        merge_backup!(raw_backup) unless raw_backup.nil?
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
        instance_eval(&) if block_given?
        self
      end

      def vpc_id(val = nil, subnet_ids: nil, subnets: nil, security_group_ids: nil, security_groups: nil)
        if val.is_a?(Hash) && (val.key?(:id) || val.key?('id') || val.key?(:vpc_id) || val.key?('vpc_id') ||
                               val.key?(:subnet_ids) || val.key?('subnet_ids') ||
                               val.key?(:subnets) || val.key?('subnets'))
          v = val[:id] || val['id'] || val[:vpc_id] || val['vpc_id']
          @vpc_id = v if v
          s = val[:subnet_ids] || val['subnet_ids'] || val[:subnets] || val['subnets']
          @subnet_ids = Array(s).flatten.compact if s
          sg = val[:security_group_ids] || val['security_group_ids'] ||
               val[:security_groups] || val['security_groups']
          @security_group_ids = Array(sg).flatten.compact if sg
        elsif !val.nil?
          @vpc_id = val
        end
        @subnet_ids = Array(subnet_ids || subnets).flatten.compact if subnet_ids || subnets
        @security_group_ids = Array(security_group_ids || security_groups).flatten.compact if security_group_ids ||
                                                                                              security_groups
      end
      alias vpc vpc_id

      def subnet_ids(*vals)
        @subnet_ids = vals.flatten.compact
      end
      alias subnets subnet_ids

      def security_group_ids(*vals)
        @security_group_ids = vals.flatten.compact
      end
      alias security_groups security_group_ids

      def deletion_policy(val)
        @deletion_policy = val
      end

      def update_replace_policy(val)
        @update_replace_policy = val
      end

      def deletion_protection(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @deletion_protection = val
      end

      def root_directory(path_or_opts = nil, path: nil, owner_uid: nil, owner_gid: nil, permissions: nil,
                         creation_info: nil)
        apply_direct_ap_options(
          root_directory: path_or_opts,
          path: path,
          creation_info: creation_info || build_inline_creation_info(owner_uid, owner_gid, permissions)
        )
      end

      def path(val)
        @ap_options[:path] = val.to_s
      end

      def posix_user(opts = nil, uid: nil, gid: nil, secondary_gids: nil)
        apply_direct_ap_options(posix_user: opts, uid: uid, gid: gid, secondary_gids: secondary_gids)
      end

      def uid(val)
        @ap_options[:uid] = val
        @posix_expectations[:uid] ||= val
      end

      def gid(val)
        @ap_options[:gid] = val
        @posix_expectations[:gid] ||= val
      end

      def secondary_gids(*vals)
        @ap_options[:secondary_gids] = vals.flatten.compact
      end

      def creation_info(opts = nil, owner_uid: nil, owner_gid: nil, permissions: nil)
        info = opts || build_inline_creation_info(owner_uid, owner_gid, permissions)
        @ap_options[:creation_info] = info if info
      end

      def tags(hash)
        @ap_options[:tags] = (@ap_options[:tags] || {}).merge(hash) if hash.is_a?(Hash)
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

      def local_path_value
        @local_path
      end

      def inline_mount_definition?
        !@access_point_source.nil? || !@managed_access_point.nil? ||
          @managed_file_system_enabled || !@subnet_ids.nil? || !@vpc_id.nil? ||
          !@security_group_helper.nil? || !@lifecycle_policies.empty? ||
          !@throughput_mode.nil? || !@provisioned_throughput_in_mibps.nil? ||
          !@encrypted.nil? || !@kms_key_id.nil? ||
          !@deletion_policy.nil? || !@update_replace_policy.nil? || !@deletion_protection.nil? ||
          (!@backup.nil? && @backup != false) || (!@alarms.nil? && @alarms != false) ||
          !@vpc_expectations.empty? || !@posix_expectations.empty? || !@ap_options.empty?
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
                    target_vpc_id = opts[:vpc_id] || opts['vpc_id'] || @vpc_id
                    extra_opts = opts.reject { |k, _| k.to_s == 'vpc_id' }
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: target_vpc_id, **extra_opts)
                  else
                    target_name = name || @symbolic_name
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: vpc_id || @vpc_id, **)
                  end
        builder.instance_eval(&) if block_given?
        @security_group_helper = builder.build
        @security_group_helper
      end
      alias efs_security_groups security_group_helper
      alias efs_security_group security_group_helper

      def build
        lifecycle = @lifecycle_policies.empty? ? nil : @lifecycle_policies
        is_mfs = @managed_file_system_enabled || !@subnet_ids.nil?
        mfs_config = if is_mfs
                       {
                         symbolic_name: @symbolic_name,
                         vpc_id: @vpc_id,
                         subnet_ids: @subnet_ids,
                         security_group_ids: @security_group_ids,
                         deletion_policy: @deletion_policy,
                         update_replace_policy: @update_replace_policy,
                         deletion_protection: @deletion_protection,
                         tags: @ap_options[:tags]
                       }
                     end
        resolved_map = @managed_access_point || (@ap_options.empty? ? nil : @ap_options)
        has_fs_config = is_mfs || !lifecycle.nil? || !@throughput_mode.nil? ||
                        !@provisioned_throughput_in_mibps.nil? ||
                        !@encrypted.nil? || !@kms_key_id.nil? ||
                        !@deletion_policy.nil? || !@update_replace_policy.nil? || !@deletion_protection.nil? ||
                        (!@backup.nil? && @backup != false) ||
                        (!@alarms.nil? && @alarms != false)
        resolved_local_path = @local_path || (resolved_map || has_fs_config ? "/mnt/#{@symbolic_name}" : nil)
        Model::EfsMount.new(
          symbolic_name: @symbolic_name,
          access_point_source: @access_point_source || @symbolic_name,
          managed_access_point: resolved_map,
          managed_file_system: mfs_config,
          security_group_helper: @security_group_helper,
          vpc_id: @vpc_id,
          subnet_ids: @subnet_ids,
          security_group_ids: @security_group_ids,
          deletion_policy: @deletion_policy,
          update_replace_policy: @update_replace_policy,
          deletion_protection: @deletion_protection,
          lifecycle_policies: lifecycle,
          throughput_mode: @throughput_mode,
          provisioned_throughput_in_mibps: @provisioned_throughput_in_mibps,
          encrypted: @encrypted,
          kms_key_id: @kms_key_id,
          backup: @backup,
          alarms: @alarms,
          local_path: resolved_local_path,
          vpc_expectations: @vpc_expectations,
          posix_expectations: @posix_expectations,
          diagnostic_policy: @diagnostic_policy
        )
      end

      private

      def apply_direct_ap_options(
        root_directory: nil,
        path: nil,
        posix_user: nil,
        uid: nil,
        gid: nil,
        secondary_gids: nil,
        creation_info: nil,
        tags: nil
      )
        @ap_options[:root_directory] = root_directory if root_directory
        @ap_options[:path] = path.to_s if path
        @ap_options[:posix_user] = posix_user if posix_user
        if uid
          @ap_options[:uid] = uid
          @posix_expectations[:uid] ||= uid
        end
        if gid
          @ap_options[:gid] = gid
          @posix_expectations[:gid] ||= gid
        end
        @ap_options[:secondary_gids] = Array(secondary_gids).flatten.compact if secondary_gids
        @ap_options[:creation_info] = creation_info if creation_info
        @ap_options[:tags] = (@ap_options[:tags] || {}).merge(tags) if tags.is_a?(Hash)
      end

      def build_inline_creation_info(owner_uid, owner_gid, permissions)
        return nil if owner_uid.nil? && owner_gid.nil? && permissions.nil?

        info = {}
        info[:owner_uid] = owner_uid unless owner_uid.nil?
        info[:owner_gid] = owner_gid unless owner_gid.nil?
        info[:permissions] = permissions unless permissions.nil?
        info
      end

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

        block_builder = ManagedAccessPointBuilder::AlarmsBlockBuilder.new(@alarms)
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

        block_builder = ManagedAccessPointBuilder::BackupBlockBuilder.new(@backup)
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
