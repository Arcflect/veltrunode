# frozen_string_literal: true

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
                  :security_group_helper

      alias name symbolic_name

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
        vpc_expectations: {},
        posix_expectations: {},
        diagnostic_policy: {}
      )
        resolved_source = access_point_source || (managed_access_point ? symbolic_name : nil)
        validate!(symbolic_name:, access_point_source: resolved_source, local_path:, managed_access_point:)

        @symbolic_name = symbolic_name.to_s.freeze
        @access_point_source = freeze_value(resolved_source)
        @local_path = local_path.to_s.freeze
        @managed_access_point = normalize_managed_access_point(managed_access_point)
        @security_group_helper = security_group_helper
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

      private

      def validate!(symbolic_name:, access_point_source:, local_path:, managed_access_point: nil)
        raise ValidationError, 'EfsMount symbolic_name is required' if blank?(symbolic_name)
        if blank?(access_point_source) && managed_access_point.nil?
          raise ValidationError, 'EfsMount access_point_source or managed_access_point is required'
        end
        raise ValidationError, 'EfsMount local_path is required' if blank?(local_path)

        validate_local_path!(local_path)
        validate_access_point_source!(access_point_source) if access_point_source
      end

      def normalize_managed_access_point(map)
        return nil if map.nil?
        return map if map.is_a?(ManagedAccessPoint)
        return ManagedAccessPoint.new(**map) if map.is_a?(Hash)

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
