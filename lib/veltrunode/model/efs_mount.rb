# frozen_string_literal: true

require_relative 'managed_access_point'

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
                  :security_group_helper,
                  :lifecycle_policies,
                  :throughput_mode,
                  :provisioned_throughput_in_mibps,
                  :backup

      alias name symbolic_name
      alias lifecycle_policy lifecycle_policies
      alias provisioned_throughput provisioned_throughput_in_mibps
      alias backup_policy backup
      alias backup_plan backup

      class << self
        def validate_unique_local_paths!(mounts)
          return if mounts.nil? || mounts.empty?

          paths = mounts.map do |m|
            if m.is_a?(Hash)
              m[:local_path] || m['local_path']
            elsif m.respond_to?(:local_path)
              m.local_path
            end
          end.compact.map(&:to_s)

          counts = Hash.new(0)
          paths.each { |p| counts[p] += 1 }
          duplicates = counts.select { |_p, c| c > 1 }.keys
          return if duplicates.empty?

          raise ValidationError, "Duplicate local_path found: #{duplicates.join(', ')}"
        end
      end

      def initialize(
        symbolic_name:,
        local_path:,
        access_point_source: nil,
        managed_access_point: nil,
        security_group_helper: nil,
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
        backup_schedule: nil,
        backup_retention_days: nil,
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
        normalized_map = normalize_managed_access_point(
          managed_access_point,
          explicit_lifecycle,
          explicit_tp_mode,
          explicit_prov_tp,
          explicit_backup
        )
        resolved_lifecycle = explicit_lifecycle || normalized_map&.lifecycle_policies
        resolved_tp_mode = explicit_tp_mode || normalized_map&.throughput_mode
        resolved_prov_tp = explicit_prov_tp || normalized_map&.provisioned_throughput_in_mibps
        resolved_backup = explicit_backup || normalized_map&.backup
        has_fs_config = !resolved_lifecycle.nil? || !resolved_tp_mode.nil? ||
                        !resolved_prov_tp.nil? || !resolved_backup.nil?
        resolved_source = access_point_source ||
                          (normalized_map || has_fs_config ? symbolic_name : nil)
        validate!(
          symbolic_name: symbolic_name,
          access_point_source: resolved_source,
          local_path: local_path,
          managed_access_point: normalized_map,
          has_fs_config: has_fs_config
        )

        @symbolic_name = symbolic_name.to_s.freeze
        @access_point_source = freeze_value(resolved_source)
        @local_path = local_path.to_s.freeze
        @managed_access_point = normalized_map
        @security_group_helper = security_group_helper
        @lifecycle_policies = resolved_lifecycle
        @throughput_mode = resolved_tp_mode
        @provisioned_throughput_in_mibps = resolved_prov_tp
        @backup = resolved_backup
        @vpc_expectations = freeze_value(vpc_expectations)
        @posix_expectations = freeze_value(posix_expectations)
        @diagnostic_policy = freeze_value(diagnostic_policy)

        freeze
      end

      def managed_access_point?
        !@managed_access_point.nil?
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

      def backup?
        !@backup.nil? && !@backup.empty?
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
        lifecycle_policies? || throughput_configuration? ||
          (backup? && (@managed_access_point.nil? || @managed_access_point.file_system_id.nil?))
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

      def normalize_managed_access_point(
        map,
        explicit_lifecycle = nil,
        explicit_tp_mode = nil,
        explicit_prov_tp = nil,
        explicit_backup = nil
      )
        return nil if map.nil?
        return map if map.is_a?(ManagedAccessPoint)

        if map.is_a?(Hash)
          opts = map.dup
          opts[:lifecycle_policies] ||= explicit_lifecycle if explicit_lifecycle
          opts[:throughput_mode] ||= explicit_tp_mode if explicit_tp_mode
          opts[:provisioned_throughput_in_mibps] ||= explicit_prov_tp if explicit_prov_tp
          opts[:backup] ||= explicit_backup if explicit_backup
          return ManagedAccessPoint.new(**opts)
        end

        map
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
