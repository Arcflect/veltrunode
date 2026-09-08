# frozen_string_literal: true

module Veltrunode
  module Model
    class StagePolicy
      attr_reader :stage,
                  :deny_wildcard_actions,
                  :require_dlq,
                  :require_log_retention,
                  :deny_public_storage

      def initialize(
        stage = nil,
        stage_name: nil,
        deny_wildcard_actions: false,
        require_dlq: false,
        require_log_retention: false,
        deny_public_storage: false
      )
        target_stage = stage || stage_name
        validate_stage!(target_stage)

        @stage = target_stage.to_s.freeze
        @deny_wildcard_actions = !deny_wildcard_actions.nil? && !(!deny_wildcard_actions)
        @require_dlq = !require_dlq.nil? && !(!require_dlq)
        @require_log_retention = !require_log_retention.nil? && !(!require_log_retention)
        @deny_public_storage = !deny_public_storage.nil? && !(!deny_public_storage)

        freeze
      end

      def deny_wildcard_actions?
        @deny_wildcard_actions
      end

      def require_dlq?
        @require_dlq
      end

      def require_log_retention?
        @require_log_retention
      end

      def deny_public_storage?
        @deny_public_storage
      end

      def applies_to?(target_stage)
        return false if target_stage.nil?

        @stage == '*' || @stage.casecmp(target_stage.to_s).zero?
      end

      private

      def validate_stage!(target_stage)
        return unless target_stage.nil? || target_stage.to_s.strip.empty?

        raise ValidationError, 'StagePolicy stage name is required'
      end
    end
  end
end
