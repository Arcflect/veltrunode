# frozen_string_literal: true

module Veltrunode
  module Model
    class StagePolicy
      attr_reader :stage,
                  :deny_wildcard_actions,
                  :require_dlq,
                  :require_log_retention,
                  :deny_public_storage,
                  :pack_name

      PRODUCTION_RULES = {
        deny_wildcard_actions: true,
        require_dlq: true,
        require_log_retention: true,
        deny_public_storage: true
      }.freeze

      def self.production_default(stage = 'production', **overrides)
        new(stage, pack_name: 'production', **PRODUCTION_RULES.merge(overrides))
      end

      def initialize(
        stage = nil,
        stage_name: nil,
        deny_wildcard_actions: false,
        require_dlq: false,
        require_log_retention: false,
        deny_public_storage: false,
        pack_name: nil
      )
        target_stage = stage || stage_name
        validate_stage!(target_stage)

        @stage = target_stage.to_s.freeze
        @deny_wildcard_actions = !deny_wildcard_actions.nil? && !(!deny_wildcard_actions)
        @require_dlq = !require_dlq.nil? && !(!require_dlq)
        @require_log_retention = !require_log_retention.nil? && !(!require_log_retention)
        @deny_public_storage = !deny_public_storage.nil? && !(!deny_public_storage)
        @pack_name = pack_name ? pack_name.to_s.freeze : nil

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

      def to_rules_hash
        {
          deny_wildcard_actions: @deny_wildcard_actions,
          require_dlq: @require_dlq,
          require_log_retention: @require_log_retention,
          deny_public_storage: @deny_public_storage
        }.freeze
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
