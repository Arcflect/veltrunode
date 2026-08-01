# frozen_string_literal: true

module Veltrunode
  module Model
    class Layer
      attr_reader :name,
                  :source_spec,
                  :compatible_runtimes,
                  :architectures,
                  :build_environment,
                  :retention_policy,
                  :description,
                  :license_metadata,
                  :content_hash

      def initialize(
        name:,
        compatible_runtimes:,
        source_spec: nil,
        architectures: [:x86_64],
        build_environment: {},
        retention_policy: { latest: 5 },
        description: nil,
        license_metadata: nil,
        content_hash: nil
      )
        validate!(name:, compatible_runtimes:, retention_policy:)

        @name = name.to_s.freeze
        @source_spec = freeze_value(source_spec)
        @compatible_runtimes = normalize_runtimes(compatible_runtimes)
        @architectures = normalize_architectures(architectures)
        @build_environment = freeze_hash(build_environment)
        @retention_policy = normalize_retention_policy(retention_policy)
        @description = description&.to_s&.freeze
        @license_metadata = freeze_value(license_metadata)
        @content_hash = content_hash&.to_s&.freeze

        freeze
      end

      private

      def validate!(name:, compatible_runtimes:, retention_policy:)
        raise ValidationError, 'Layer name is required' if blank?(name)
        if empty_collection?(compatible_runtimes)
          raise ValidationError, 'Layer compatible_runtimes is required and cannot be empty'
        end

        validate_retention_policy!(retention_policy)
      end

      def validate_retention_policy!(policy)
        return if policy.nil?

        raise ValidationError, 'retention_policy must be a Hash (e.g. { latest: N })' unless policy.is_a?(Hash)

        latest = policy[:latest] || policy['latest']
        return unless latest

        return if latest.is_a?(Integer) && latest.positive?

        raise ValidationError, 'retention_policy latest must be a positive integer'
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end

      def empty_collection?(col)
        col.nil? || (col.respond_to?(:empty?) && col.empty?)
      end

      def normalize_runtimes(runtimes)
        Array(runtimes).map { |r| r.to_s.freeze }.freeze
      end

      def normalize_architectures(archs)
        Array(archs).map { |a| a.to_s.to_sym }.freeze
      end

      def normalize_retention_policy(policy)
        return {}.freeze if policy.nil?

        hash = policy.dup
        latest = hash.delete(:latest) || hash.delete('latest')

        # Ensure the other form of the key can't overwrite :latest in the loop
        hash.delete(:latest)
        hash.delete('latest')

        res = {}
        res[:latest] = latest.to_i if latest
        hash.each { |k, v| res[k.to_sym] = v }
        res.freeze
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
