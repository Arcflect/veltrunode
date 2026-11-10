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
                  :lifecycle_policies

      alias name symbolic_name
      alias lifecycle_policy lifecycle_policies

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
        normalized_map = normalize_managed_access_point(managed_access_point, explicit_lifecycle)
        resolved_lifecycle = explicit_lifecycle || normalized_map&.lifecycle_policies
        resolved_source = access_point_source ||
                          (normalized_map || resolved_lifecycle ? symbolic_name : nil)
        validate!(
          symbolic_name: symbolic_name,
          access_point_source: resolved_source,
          local_path: local_path,
          managed_access_point: normalized_map,
          lifecycle_policies: resolved_lifecycle
        )

        @symbolic_name = symbolic_name.to_s.freeze
        @access_point_source = freeze_value(resolved_source)
        @local_path = local_path.to_s.freeze
        @managed_access_point = normalized_map
        @security_group_helper = security_group_helper
        @lifecycle_policies = resolved_lifecycle
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
                    lifecycle_policies: nil)
        raise ValidationError, 'EfsMount symbolic_name is required' if blank?(symbolic_name)
        if blank?(access_point_source) && managed_access_point.nil? && lifecycle_policies.nil?
          raise ValidationError, 'EfsMount access_point_source or managed_access_point is required'
        end
        raise ValidationError, 'EfsMount local_path is required' if blank?(local_path)

        validate_local_path!(local_path)
        validate_access_point_source!(access_point_source) if access_point_source
      end

      def normalize_managed_access_point(map, explicit_lifecycle = nil)
        return nil if map.nil?
        return map if map.is_a?(ManagedAccessPoint)

        if map.is_a?(Hash)
          opts = map.dup
          opts[:lifecycle_policies] ||= explicit_lifecycle if explicit_lifecycle
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
