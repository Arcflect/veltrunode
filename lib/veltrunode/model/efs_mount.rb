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
                  :diagnostic_policy

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

          duplicates = paths.select { |p| paths.count(p) > 1 }.uniq
          return if duplicates.empty?

          raise ValidationError, "Duplicate local_path found: #{duplicates.join(', ')}"
        end
      end

      def initialize(
        symbolic_name:,
        access_point_source:,
        local_path:,
        vpc_expectations: {},
        posix_expectations: {},
        diagnostic_policy: {}
      )
        validate!(symbolic_name:, access_point_source:, local_path:)

        @symbolic_name = symbolic_name.to_s.freeze
        @access_point_source = access_point_source.to_s.freeze
        @local_path = local_path.to_s.freeze
        @vpc_expectations = freeze_value(vpc_expectations)
        @posix_expectations = freeze_value(posix_expectations)
        @diagnostic_policy = freeze_value(diagnostic_policy)

        freeze
      end

      private

      def validate!(symbolic_name:, access_point_source:, local_path:)
        raise ValidationError, 'EfsMount symbolic_name is required' if blank?(symbolic_name)
        raise ValidationError, 'EfsMount access_point_source is required' if blank?(access_point_source)
        raise ValidationError, 'EfsMount local_path is required' if blank?(local_path)

        validate_local_path!(local_path)
        validate_access_point_source!(access_point_source)
      end

      def validate_local_path!(path)
        return if path.to_s.start_with?('/mnt/')

        raise ValidationError, "EfsMount local_path '#{path}' must start with '/mnt/'"
      end

      def validate_access_point_source!(source)
        src_str = source.to_s.strip
        return unless src_str.start_with?('arn:')

        return if ARN_PATTERN.match?(src_str)

        raise ValidationError,
              "Invalid EFS access point ARN '#{src_str}'. " \
              'Must match arn:aws:elasticfilesystem:<region>:<account>:access-point/fsap-*'
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
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
          memo[k.to_s.freeze] = freeze_value(v)
        end.freeze
      end
    end
  end
end
