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
        positional_name = nil,
        name: nil,
        region: 'ap-northeast-1',
        stage: 'dev',
        account_constraint: nil,
        runtime_defaults: {},
        functions: [],
        layers: [],
        schedules: [],
        mounts: [],
        policies: [],
        tags: {}
      )
        app_name = positional_name || name
        validate!(name: app_name, region: region, stage: stage)

        @name = app_name.to_s.freeze
        @region = region.to_s.freeze
        @stage = stage.to_s.freeze
        @account_constraint = account_constraint&.to_s&.freeze
        @runtime_defaults = runtime_defaults.dup.freeze
        @functions = normalize_collection_with_lookup(functions, :logical_name).freeze
        @layers = layers.dup.freeze
        @schedules = schedules.dup.freeze
        @mounts = mounts.dup.freeze
        @policies = policies.dup.freeze
        @tags = tags.dup.freeze

        freeze
      end

      def account
        account_constraint
      end

      def runtime
        ruby_ver = runtime_defaults[:ruby] || runtime_defaults['ruby']
        ruby_ver ? "ruby#{ruby_ver.to_s.sub('ruby', '')}" : nil
      end

      def architecture
        runtime_defaults[:architecture] || runtime_defaults['architecture']
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

      def normalize_collection_with_lookup(collection, key_method)
        arr = Array(collection).dup
        arr.define_singleton_method(:[]) do |key|
          if key.is_a?(Integer)
            super(key)
          else
            find do |item|
              item_name = item.respond_to?(key_method) ? item.public_send(key_method) : nil
              item_name.to_s == key.to_s
            end
          end
        end
        arr
      end
    end
  end
end
