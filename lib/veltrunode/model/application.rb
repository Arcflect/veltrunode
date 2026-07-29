# frozen_string_literal: true

module Veltrunode
  module Model
    class Application
      attr_reader :name,
                  :region,
                  :stage,
                  :account_constraint,
                  :runtime_defaults,
                  :functions,
                  :layers,
                  :schedules,
                  :mounts,
                  :policies,
                  :tags

      def initialize(
        name:,
        region:,
        stage:,
        account_constraint: nil,
        runtime_defaults: {},
        functions: [],
        layers: [],
        schedules: [],
        mounts: [],
        policies: [],
        tags: {}
      )
        validate!(name: name, region: region, stage: stage)

        @name = name.to_s.freeze
        @region = region.to_s.freeze
        @stage = stage.to_s.freeze
        @account_constraint = account_constraint&.to_s&.freeze
        @runtime_defaults = runtime_defaults.dup.freeze
        @functions = functions.dup.freeze
        @layers = layers.dup.freeze
        @schedules = schedules.dup.freeze
        @mounts = mounts.dup.freeze
        @policies = policies.dup.freeze
        @tags = tags.dup.freeze

        freeze
      end

      private

      def validate!(name:, region:, stage:)
        raise ValidationError, 'Application name is required' if blank?(name)
        raise ValidationError, 'Application region is required' if blank?(region)
        raise ValidationError, 'Application stage is required' if blank?(stage)
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end
    end
  end
end
