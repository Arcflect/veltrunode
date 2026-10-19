# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Model
    # CloudWatch Logs サブスクリプションフィルター定義モデル
    class SubscriptionFilter
      VALID_DESTINATION_TYPES = %i[lambda kinesis firehose auto].freeze
      VALID_DISTRIBUTIONS = %w[ByLogStream Random].freeze

      attr_reader :name,
                  :destination,
                  :filter_pattern,
                  :destination_type,
                  :role_arn,
                  :distribution

      def initialize(
        destination:,
        name: nil,
        filter_pattern: '',
        destination_type: :auto,
        role_arn: nil,
        distribution: nil
      )
        @name = name&.to_sym
        @destination = normalize_destination(destination)
        @filter_pattern = validate_and_normalize_pattern(filter_pattern)
        @destination_type = normalize_destination_type(destination_type)
        @role_arn = normalize_role_arn(role_arn)
        @distribution = validate_and_normalize_distribution(distribution)

        validate!
        freeze
      end

      # 宛先種別を判定（auto の場合は推論）
      def resolved_destination_type
        return @destination_type unless @destination_type == :auto

        infer_destination_type
      end

      def lambda_destination?
        resolved_destination_type == :lambda
      end

      def kinesis_destination?
        resolved_destination_type == :kinesis
      end

      def firehose_destination?
        resolved_destination_type == :firehose
      end

      def validate!
        validate_destination!
        validate_destination_type!
      end

      private

      def validate_and_normalize_pattern(pattern)
        p = pattern || ''
        unless p.is_a?(String)
          raise ValidationError, "SubscriptionFilter filter_pattern must be a String, got #{p.class}"
        end

        p.freeze
      end

      def validate_and_normalize_distribution(dist)
        return nil if dist.nil?

        dist_str = dist.to_s
        unless VALID_DISTRIBUTIONS.include?(dist_str)
          raise ValidationError, "Invalid distribution: #{dist_str}. Valid values are #{VALID_DISTRIBUTIONS.join(', ')}"
        end

        dist_str.freeze
      end

      def normalize_destination(dest)
        if dest.is_a?(Hash)
          freeze_hash(dest)
        elsif dest.respond_to?(:name) || dest.is_a?(Symbol)
          dest
        elsif dest
          dest.to_s.strip.freeze
        end
      end

      def normalize_destination_type(type)
        (type || :auto).to_s.downcase.to_sym
      end

      def normalize_role_arn(role)
        if role.is_a?(Hash)
          freeze_hash(role)
        elsif role.respond_to?(:name) || role.is_a?(Symbol)
          role
        elsif role
          role.to_s.strip.freeze
        end
      end

      def infer_destination_type
        dest_str = destination_as_string.downcase

        if dest_str.include?(':firehose:') || dest_str.include?('firehose')
          :firehose
        elsif dest_str.include?(':kinesis:') || dest_str.include?('kinesis')
          :kinesis
        else
          :lambda
        end
      end

      def destination_as_string
        if @destination.respond_to?(:name)
          @destination.name.to_s
        else
          @destination.to_s
        end
      end

      def validate_destination!
        return unless @destination.nil? || (@destination.is_a?(String) && @destination.strip.empty?)

        raise ValidationError, 'SubscriptionFilter destination is required'
      end

      def validate_destination_type!
        return if VALID_DESTINATION_TYPES.include?(@destination_type)

        raise ValidationError, "Unsupported destination_type: #{@destination_type}. " \
                               "Valid types are #{VALID_DESTINATION_TYPES.join(', ')}"
      end

      def freeze_hash(hash)
        hash.each_with_object({}) do |(k, v), memo|
          frozen_val = v.is_a?(Hash) ? freeze_hash(v) : v.to_s.freeze
          memo[k.to_s.freeze] = frozen_val
        end.freeze
      end
    end
  end
end
