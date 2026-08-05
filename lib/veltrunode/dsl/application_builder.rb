# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'layer_builder'
require_relative 'efs_mount_builder'
require_relative 'function_builder'
require_relative 'schedule_builder'
require_relative '../model/application'

module Veltrunode
  module DSL
    class ApplicationBuilder < BaseBuilder
      def initialize(name)
        super()
        @name = name.to_s
        @region = 'ap-northeast-1'
        @stage = 'dev'
        @account_constraint = nil
        @runtime_defaults = {}
        @function_builders = []
        @layer_builders = []
        @schedule_builders = []
        @efs_mount_builders = []
        @policies = []
        @tags = {}
      end

      def aws(region: nil, account: nil, account_constraint: nil)
        @region = region.to_s if region
        @account_constraint = (account || account_constraint)&.to_s
      end

      def stage(st)
        @stage = st.to_s
      end

      def runtime(ruby: nil, architecture: nil)
        @runtime_defaults[:ruby] = ruby.to_s if ruby
        @runtime_defaults[:architecture] = architecture.to_sym if architecture
      end

      def defaults(&)
        return unless block_given?

        defaults_builder = DefaultsBuilder.new
        defaults_builder.instance_eval(&)
        @runtime_defaults[:logs] = defaults_builder.logs_config if defaults_builder.logs_config
        @tags.merge!(defaults_builder.tags_config)
      end

      def layer(name, &)
        builder = LayerBuilder.new(name, runtime_default: @runtime_defaults[:ruby] || 'ruby3.3')
        builder.instance_eval(&) if block_given?
        @layer_builders << builder
      end

      def efs_mount(name, &)
        builder = EfsMountBuilder.new(name)
        builder.instance_eval(&) if block_given?
        @efs_mount_builders << builder
      end

      def function(name, &)
        ruby_default = @runtime_defaults[:ruby] ? "ruby#{runtime_version_normalized(@runtime_defaults[:ruby])}" : nil
        builder = FunctionBuilder.new(
          name,
          runtime_default: ruby_default,
          architecture_default: @runtime_defaults[:architecture] || :x86_64
        )
        builder.instance_eval(&) if block_given?
        @function_builders << builder
      end

      def schedule(name, &)
        builder = ScheduleBuilder.new(name)
        builder.instance_eval(&) if block_given?
        @schedule_builders << builder
      end

      def build
        layers = @layer_builders.map(&:build)
        mounts = @efs_mount_builders.map(&:build)
        functions = @function_builders.map(&:build)
        schedules = @schedule_builders.map(&:build)

        Model::Application.new(
          name: @name,
          region: @region,
          stage: @stage,
          account_constraint: @account_constraint,
          runtime_defaults: @runtime_defaults,
          functions: functions,
          layers: layers,
          schedules: schedules,
          mounts: mounts,
          policies: @policies,
          tags: @tags
        )
      end

      private

      def runtime_version_normalized(ver)
        v = ver.to_s
        v.start_with?('ruby') ? v.sub('ruby', '') : v
      end
    end

    class DefaultsBuilder < BaseBuilder
      attr_reader :logs_config, :tags_config

      def initialize
        super
        @logs_config = nil
        @tags_config = {}
      end

      def logs(retention_days: nil)
        @logs_config = { retention_days: retention_days.to_i }.compact
      end

      def tags(hash = {})
        @tags_config.merge!(hash)
      end
    end
  end
end
