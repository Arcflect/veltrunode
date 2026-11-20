# frozen_string_literal: true

require_relative 'managed_access_point'
require_relative 'managed_file_system'
require_relative 'security_group_helper'

module Veltrunode
  module Model
    class EfsMount
      ARN_PATTERN = %r{\Aarn:aws:elasticfilesystem:[a-z0-9-]+:\d{12}:access-point/fsap-[a-f0-9]+\z}

      attr_reader :symbolic_name,
                  :access_point_source,
                  :local_path,
                  :vpc_expectations,
                  :posix_expectations,
                  :diagnostic_policy,
                  :managed_access_point,
                  :managed_file_system,
                  :security_group_helper,
                  :lifecycle_policies,
                  :throughput_mode,
                  :provisioned_throughput_in_mibps,
                  :encrypted,
                  :kms_key_id,
                  :backup,
                  :alarms,
                  :deletion_policy,
                  :update_replace_policy

      alias name symbolic_name
      alias lifecycle_policy lifecycle_policies
      alias provisioned_throughput provisioned_throughput_in_mibps
      alias kms_key kms_key_id
      alias kms_key_arn kms_key_id
      alias backup_policy backup
      alias backup_plan backup
      alias efs_alarms alarms

      class << self
        def validate_unique_local_paths!(mounts, mount_map: {})
          duplicates = duplicate_local_paths(mounts, mount_map: mount_map)
          return if duplicates.empty?

          raise ValidationError, "Duplicate local_path found: #{duplicates.join(', ')}"
        end

        def duplicate_local_paths(mounts, mount_map: {})
          return [] if mounts.nil? || mounts.empty?

          paths = Array(mounts).map { |m| extract_local_path_for_validation(m, mount_map) }.compact.map(&:to_s)
          counts = Hash.new(0)
          paths.each { |p| counts[p] += 1 }
          counts.select { |_p, c| c > 1 }.keys
        end

        private

        def extract_local_path_for_validation(mount, mount_map)
          if mount.is_a?(Hash)
            explicit = mount[:local_path] || mount['local_path'] ||
                       mount[:local_mount_path] || mount['local_mount_path'] || mount['LocalMountPath']
            return explicit if explicit

            name = mount[:name] || mount['name'] || mount[:symbolic_name] || mount['symbolic_name'] ||
                   mount[:mount] || mount['mount']
            resolve_from_mount_map(name, mount_map)
          elsif mount.respond_to?(:local_path)
            mount.local_path
          elsif mount.is_a?(String) && mount.include?(':')
            mount.split(':', 2).last
          elsif mount.is_a?(String) && mount.start_with?('/')
            mount
          elsif mount.is_a?(String) || mount.is_a?(Symbol)
            resolve_from_mount_map(mount, mount_map)
          end
        end

        def resolve_from_mount_map(name, mount_map)
          return nil if name.nil? || mount_map.nil? || mount_map.empty?

          target = if mount_map.is_a?(Hash)
                     mount_map[name.to_s] || mount_map[name.to_sym]
                   elsif mount_map.is_a?(Array)
                     mount_map.find { |item| extract_mount_item_name(item) == name.to_s }
                   end
          return nil unless target

          target.respond_to?(:local_path) ? target.local_path : (target[:local_path] || target['local_path'])
        end

        def extract_mount_item_name(item)
          if item.respond_to?(:symbolic_name)
            item.symbolic_name.to_s
          elsif item.respond_to?(:name)
            item.name.to_s
          elsif item.is_a?(Hash)
            (item[:name] || item['name'] || item[:symbolic_name] || item['symbolic_name'])&.to_s
          end
        end
      end

      def initialize(
        symbolic_name:,
        local_path: nil,
        access_point_source: nil,
        managed_access_point: nil,
        managed_file_system: nil,
        security_group_helper: nil,
        vpc_id: nil,
        subnet_ids: nil,
        subnets: nil,
        security_group_ids: nil,
        deletion_policy: nil,
        update_replace_policy: nil,
        deletion_protection: nil,
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
        backup_schedule: nil,
        backup_retention_days: nil,
        alarms: nil,
        efs_alarms: nil,
        burst_credit_balance: nil,
        burst_credit_balance_threshold: nil,
        burst_credit_threshold: nil,
        percent_io_limit: nil,
        percent_io_limit_threshold: nil,
        io_limit_threshold: nil,
        alarm_topic: nil,
        vpc_expectations: {},
        posix_expectations: {},
        diagnostic_policy: {}
      )
        explicit_lifecycle = ManagedAccessPoint.normalize_lifecycle_policies(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        explicit_tp_mode, explicit_prov_tp = ManagedAccessPoint.normalize_throughput_config(
          throughput_mode: throughput_mode,
          provisioned_throughput_in_mibps: provisioned_throughput_in_mibps,
          provisioned_throughput: provisioned_throughput
        )
        explicit_enc, explicit_kms = ManagedAccessPoint.normalize_encryption_config(
          encrypted: encrypted,
          kms_key_id: kms_key_id,
          kms_key: kms_key,
          kms_key_arn: kms_key_arn
        )
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        explicit_backup = ManagedAccessPoint.normalize_backup_config(
          raw_backup,
          schedule: backup_schedule,
          retention_days: backup_retention_days
        )
        raw_alarms = alarms.nil? ? efs_alarms : alarms
        explicit_alarms = ManagedAccessPoint.normalize_alarms_config(
          raw_alarms,
          burst_credit_balance: burst_credit_balance,
          burst_credit_balance_threshold: burst_credit_balance_threshold,
          burst_credit_threshold: burst_credit_threshold,
          percent_io_limit: percent_io_limit,
          percent_io_limit_threshold: percent_io_limit_threshold,
          io_limit_threshold: io_limit_threshold,
          topic: alarm_topic
        )
        normalized_mfs = normalize_managed_file_system(
          managed_file_system,
          symbolic_name: symbolic_name,
          vpc_id: vpc_id,
          subnet_ids: subnet_ids || subnets,
          security_group_ids: security_group_ids,
          deletion_policy: deletion_policy,
          update_replace_policy: update_replace_policy,
          deletion_protection: deletion_protection,
          explicit_lifecycle: explicit_lifecycle,
          explicit_tp_mode: explicit_tp_mode,
          explicit_prov_tp: explicit_prov_tp,
          explicit_backup: explicit_backup,
          explicit_alarms: explicit_alarms,
          explicit_enc: explicit_enc,
          explicit_kms: explicit_kms
        )
        resolved_lifecycle = explicit_lifecycle || normalized_mfs&.lifecycle_policies
        resolved_tp_mode = explicit_tp_mode || normalized_mfs&.throughput_mode
        resolved_prov_tp = explicit_prov_tp || normalized_mfs&.provisioned_throughput_in_mibps
        resolved_enc = explicit_enc.nil? ? normalized_mfs&.encrypted : explicit_enc
        resolved_kms = explicit_kms || normalized_mfs&.kms_key_id
        resolved_backup = explicit_backup || normalized_mfs&.backup
        resolved_alarms = explicit_alarms || normalized_mfs&.alarms

        normalized_map = normalize_managed_access_point(
          managed_access_point,
          resolved_lifecycle,
          resolved_tp_mode,
          resolved_prov_tp,
          resolved_backup,
          resolved_alarms,
          resolved_enc,
          resolved_kms,
          managed_file_system: normalized_mfs,
          posix_expectations: posix_expectations
        )
        resolved_lifecycle ||= normalized_map&.lifecycle_policies
        resolved_tp_mode ||= normalized_map&.throughput_mode
        resolved_prov_tp ||= normalized_map&.provisioned_throughput_in_mibps
        resolved_enc = normalized_map&.encrypted if resolved_enc.nil?
        resolved_kms ||= normalized_map&.kms_key_id
        resolved_backup ||= normalized_map&.backup
        resolved_alarms ||= normalized_map&.alarms

        resolved_del_policy, resolved_upd_policy = resolve_deletion_policies(
          normalized_mfs,
          deletion_policy: deletion_policy,
          update_replace_policy: update_replace_policy,
          deletion_protection: deletion_protection
        )
        resolved_sg_helper = resolve_security_group_helper(
          security_group_helper,
          normalized_mfs,
          symbolic_name: symbolic_name
        )
        resolved_vpc_expectations = merge_mfs_vpc_expectations(vpc_expectations, normalized_mfs)
        resolved_local_path = if local_path.nil? && normalized_mfs && !blank?(symbolic_name)
                                "/mnt/#{symbolic_name}"
                              else
                                local_path
                              end

        has_fs_config = !normalized_mfs.nil? || !resolved_lifecycle.nil? || !resolved_tp_mode.nil? ||
                        !resolved_prov_tp.nil? || !resolved_enc.nil? || !resolved_kms.nil? ||
                        !resolved_backup.nil? || !resolved_alarms.nil?
        resolved_source = access_point_source ||
                          (normalized_map || has_fs_config ? symbolic_name : nil)
        validate!(
          symbolic_name: symbolic_name,
          access_point_source: resolved_source,
          local_path: resolved_local_path,
          managed_access_point: normalized_map,
          has_fs_config: has_fs_config
        )

        @symbolic_name = symbolic_name.to_s.freeze
        @access_point_source = freeze_value(resolved_source)
        @local_path = resolved_local_path.to_s.freeze
        @managed_access_point = normalized_map
        @managed_file_system = normalized_mfs
        @security_group_helper = resolved_sg_helper
        @lifecycle_policies = resolved_lifecycle
        @throughput_mode = resolved_tp_mode
        @provisioned_throughput_in_mibps = resolved_prov_tp
        @encrypted = resolved_enc
        @kms_key_id = resolved_kms
        @backup = resolved_backup
        @alarms = resolved_alarms
        @deletion_policy = resolved_del_policy
        @update_replace_policy = resolved_upd_policy
        @vpc_expectations = freeze_value(resolved_vpc_expectations)
        @posix_expectations = freeze_value(posix_expectations)
        @diagnostic_policy = freeze_value(diagnostic_policy)

        freeze
      end

      def managed_access_point?
        !@managed_access_point.nil?
      end

      def managed_file_system?
        !@managed_file_system.nil?
      end

      def subnet_ids
        if @managed_file_system
          @managed_file_system.subnet_ids
        elsif @vpc_expectations.is_a?(Hash) && @vpc_expectations['subnet_ids']
          Array(@vpc_expectations['subnet_ids'])
        else
          [].freeze
        end
      end
      alias subnets subnet_ids

      def vpc_id
        @managed_file_system&.vpc_id || @security_group_helper&.vpc_id ||
          (@vpc_expectations.is_a?(Hash) ? @vpc_expectations['vpc_id'] : nil)
      end

      def security_group_ids
        if @managed_file_system && !@managed_file_system.security_group_ids.empty?
          @managed_file_system.security_group_ids
        elsif @vpc_expectations.is_a?(Hash) && @vpc_expectations['security_group_ids']
          Array(@vpc_expectations['security_group_ids'])
        else
          [].freeze
        end
      end

      def deletion_protection?
        @deletion_policy == 'Retain' && @update_replace_policy == 'Retain'
      end

      def security_group_helper?
        !@security_group_helper.nil?
      end

      def lifecycle_policies?
        !@lifecycle_policies.nil? && !@lifecycle_policies.empty?
      end

      def throughput_configuration?
        !@throughput_mode.nil? || !@provisioned_throughput_in_mibps.nil?
      end

      def encrypted?
        @encrypted == true || !@kms_key_id.nil?
      end

      def kms_key?
        !@kms_key_id.nil?
      end
      alias customer_managed_kms_key? kms_key?

      def encryption_configuration?
        !@encrypted.nil? || !@kms_key_id.nil?
      end

      def backup?
        !@backup.nil? && !@backup.empty?
      end

      def alarms?
        !@alarms.nil? && !@alarms.empty?
      end
      alias efs_alarms? alarms?

      def burst_credit_balance_threshold
        @alarms&.dig('burst_credit_balance', 'threshold')
      end
      alias burst_credit_threshold burst_credit_balance_threshold

      def percent_io_limit_threshold
        @alarms&.dig('percent_io_limit', 'threshold')
      end
      alias io_limit_threshold percent_io_limit_threshold

      def alarm_topic
        @alarms&.fetch('topic', nil)
      end

      def backup_schedule
        @backup&.fetch('schedule', nil)
      end

      def backup_retention_days
        @backup&.fetch('retention_days', nil)
      end

      def backup_cold_storage_after_days
        @backup&.fetch('cold_storage_after_days', nil)
      end

      def file_system_configuration?
        managed_file_system? || lifecycle_policies? || throughput_configuration? || encryption_configuration? ||
          !@deletion_policy.nil? || !@update_replace_policy.nil? ||
          ((backup? || alarms?) && (@managed_access_point.nil? || @managed_access_point.file_system_id.nil?))
      end

      def transition_to_ia
        @lifecycle_policies&.fetch('transition_to_ia', nil)
      end

      def transition_to_archive
        @lifecycle_policies&.fetch('transition_to_archive', nil)
      end

      def transition_to_primary_storage_class
        @lifecycle_policies&.fetch('transition_to_primary_storage_class', nil)
      end

      private

      def validate!(symbolic_name:, access_point_source:, local_path:, managed_access_point: nil,
                    has_fs_config: false)
        raise ValidationError, 'EfsMount symbolic_name is required' if blank?(symbolic_name)
        if blank?(access_point_source) && managed_access_point.nil? && !has_fs_config
          raise ValidationError, 'EfsMount access_point_source or managed_access_point is required'
        end
        raise ValidationError, 'EfsMount local_path is required' if blank?(local_path)

        validate_local_path!(local_path)
        validate_access_point_source!(access_point_source) if access_point_source
      end

      def normalize_managed_file_system(
        mfs,
        symbolic_name:,
        vpc_id:,
        subnet_ids:,
        security_group_ids:,
        deletion_policy:,
        update_replace_policy:,
        deletion_protection:,
        explicit_lifecycle:,
        explicit_tp_mode:,
        explicit_prov_tp:,
        explicit_backup:,
        explicit_alarms:,
        explicit_enc:,
        explicit_kms:
      )
        return mfs if mfs.is_a?(ManagedFileSystem)
        return nil if mfs.nil? && subnet_ids.nil?

        opts = mfs.is_a?(Hash) ? mfs.dup : {}
        opts[:symbolic_name] ||= symbolic_name
        opts[:vpc_id] ||= vpc_id if vpc_id
        opts[:subnet_ids] ||= subnet_ids if subnet_ids
        opts[:security_group_ids] ||= security_group_ids if security_group_ids
        opts[:deletion_policy] ||= deletion_policy unless deletion_policy.nil?
        opts[:update_replace_policy] ||= update_replace_policy unless update_replace_policy.nil?
        opts[:deletion_protection] = deletion_protection if opts[:deletion_protection].nil? && !deletion_protection.nil?
        opts[:lifecycle_policies] ||= explicit_lifecycle if explicit_lifecycle
        opts[:throughput_mode] ||= explicit_tp_mode if explicit_tp_mode
        opts[:provisioned_throughput_in_mibps] ||= explicit_prov_tp if explicit_prov_tp
        opts[:backup] ||= explicit_backup if explicit_backup
        opts[:alarms] ||= explicit_alarms if explicit_alarms
        opts[:encrypted] = explicit_enc if opts[:encrypted].nil? && !explicit_enc.nil?
        opts[:kms_key_id] ||= explicit_kms if explicit_kms

        ManagedFileSystem.new(**opts)
      end

      def normalize_managed_access_point(
        map,
        explicit_lifecycle = nil,
        explicit_tp_mode = nil,
        explicit_prov_tp = nil,
        explicit_backup = nil,
        explicit_alarms = nil,
        explicit_enc = nil,
        explicit_kms = nil,
        managed_file_system: nil,
        posix_expectations: {}
      )
        return map if map.is_a?(ManagedAccessPoint)
        return nil if map.nil? && managed_file_system.nil?

        opts = map.is_a?(Hash) ? map.dup : {}
        if managed_file_system && !opts.key?(:posix_user) && !opts.key?('posix_user') &&
           !opts.key?(:uid) && !opts.key?('uid')
          p_uid = posix_expectations[:uid] || posix_expectations['uid'] || 1000
          p_gid = posix_expectations[:gid] || posix_expectations['gid'] || 1000
          opts[:posix_user] = { uid: p_uid, gid: p_gid }
        end
        opts[:lifecycle_policies] ||= explicit_lifecycle if explicit_lifecycle
        opts[:throughput_mode] ||= explicit_tp_mode if explicit_tp_mode
        opts[:provisioned_throughput_in_mibps] ||= explicit_prov_tp if explicit_prov_tp
        opts[:backup] ||= explicit_backup if explicit_backup
        opts[:alarms] ||= explicit_alarms if explicit_alarms
        opts[:encrypted] = explicit_enc if opts[:encrypted].nil? && !explicit_enc.nil?
        opts[:kms_key_id] ||= explicit_kms if explicit_kms
        opts[:tags] ||= managed_file_system.tags if managed_file_system && !managed_file_system.tags.empty?
        ManagedAccessPoint.new(**opts)
      end

      def resolve_deletion_policies(mfs, deletion_policy:, update_replace_policy:, deletion_protection:)
        if mfs
          [mfs.deletion_policy, mfs.update_replace_policy]
        elsif !deletion_policy.nil? || !update_replace_policy.nil? || !deletion_protection.nil?
          [
            ManagedFileSystem.normalize_deletion_policy(deletion_policy, deletion_protection: deletion_protection),
            ManagedFileSystem.normalize_update_replace_policy(
              update_replace_policy,
              deletion_protection: deletion_protection
            )
          ]
        else
          [nil, nil]
        end
      end

      def resolve_security_group_helper(sg_helper, mfs, symbolic_name:)
        return sg_helper unless sg_helper.nil?
        return nil unless mfs&.vpc_id

        SecurityGroupHelper.new(
          symbolic_name: symbolic_name,
          vpc_id: mfs.vpc_id,
          tags: mfs.tags
        )
      end

      def merge_mfs_vpc_expectations(vpc_expectations, mfs)
        base = vpc_expectations.is_a?(Hash) ? vpc_expectations.dup : {}
        return base unless mfs

        base['subnet_ids'] ||= mfs.subnet_ids unless mfs.subnet_ids.empty?
        base['vpc_id'] ||= mfs.vpc_id if mfs.vpc_id
        base['security_group_ids'] ||= mfs.security_group_ids unless mfs.security_group_ids.empty?
        base
      end

      def validate_local_path!(path)
        return if path.to_s.start_with?('/mnt/')

        raise ValidationError, "EfsMount local_path '#{path}' must start with '/mnt/'"
      end

      def validate_access_point_source!(source)
        return if source.is_a?(Hash)

        src_str = source.to_s.strip
        return unless src_str.start_with?('arn:')

        return if ARN_PATTERN.match?(src_str)

        raise ValidationError,
              "Invalid EFS access point ARN '#{src_str}'. " \
              'Must match arn:aws:elasticfilesystem:<region>:<account>:access-point/fsap-*'
      end

      def blank?(val)
        val.nil? || (val.respond_to?(:empty?) ? val.empty? : val.to_s.strip.empty?)
      end

      def freeze_value(val)
        case val
        when Hash
          freeze_hash(val)
        when Array
          val.map { |item| freeze_value(item) }.freeze
        when String
          val.dup.freeze
        else
          val.frozen? ? val : val.freeze
        end
      end

      def freeze_hash(hash)
        return {}.freeze if hash.nil?

        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.dup.freeze] = freeze_value(v)
        end.freeze
      end
    end
  end
end
