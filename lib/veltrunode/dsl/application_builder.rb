# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'layer_builder'
require_relative 'efs_mount_builder'
require_relative 'function_builder'
require_relative 'schedule_builder'
require_relative '../model/application'
require_relative '../model/stage_policy'

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

      def runtime(arg = nil, ruby: nil, python: nil, nodejs: nil, node: nil, architecture: nil)
        apply_positional_runtime(arg.to_s) if arg
        @runtime_defaults[:ruby] = normalize_version(ruby, 'ruby') if ruby
        @runtime_defaults[:python] = normalize_version(python, 'python') if python
        node_val = nodejs || node
        @runtime_defaults[:nodejs] = normalize_version(node_val, 'node') if node_val
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
        builder = LayerBuilder.new(name, runtime_default: resolve_default_runtime || 'ruby3.3')
        builder.instance_eval(&) if block_given?
        @layer_builders << builder
      end

      def efs_mount(name, &)
        builder = EfsMountBuilder.new(name)
        builder.instance_eval(&) if block_given?
        @efs_mount_builders << builder
      end

      def function(name, &)
        builder = FunctionBuilder.new(
          name,
          runtime_default: resolve_default_runtime,
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

      def stage_policy(stage, deny_wildcard_actions: false, require_dlq: false, require_log_retention: false,
                       deny_public_storage: false, &)
        builder = StagePolicyBuilder.new(
          stage,
          deny_wildcard_actions: deny_wildcard_actions,
          require_dlq: require_dlq,
          require_log_retention: require_log_retention,
          deny_public_storage: deny_public_storage
        )
        builder.instance_eval(&) if block_given?
        @policies << builder.build
      end
      alias policy stage_policy

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

      def apply_positional_runtime(str)
        if str.start_with?('python')
          @runtime_defaults[:python] = normalize_version(str.sub('python', ''), 'python')
        elsif str.start_with?('nodejs') || str.start_with?('node')
          @runtime_defaults[:nodejs] = normalize_version(str.sub(/^node(js)?/, ''), 'node')
        elsif str.start_with?('ruby')
          @runtime_defaults[:ruby] = normalize_version(str.sub('ruby', ''), 'ruby')
        end
      end

      def normalize_version(ver, prefix)
        v = ver.to_s
        if prefix == 'node'
          v.sub(/^node(js)?/, '')
        else
          v.start_with?(prefix) ? v.sub(prefix, '') : v
        end
      end

      def resolve_default_runtime
        if @runtime_defaults[:python]
          "python#{@runtime_defaults[:python]}"
        elsif @runtime_defaults[:nodejs]
          "nodejs#{@runtime_defaults[:nodejs]}"
        elsif @runtime_defaults[:ruby]
          "ruby#{@runtime_defaults[:ruby]}"
        end
      end
    end

    class StagePolicyBuilder < BaseBuilder
      def initialize(stage, deny_wildcard_actions: false, require_dlq: false, require_log_retention: false,
                     deny_public_storage: false)
        super()
        @stage = stage
        @deny_wildcard_actions = deny_wildcard_actions
        @require_dlq = require_dlq
        @require_log_retention = require_log_retention
        @deny_public_storage = deny_public_storage
      end

      def deny_wildcard_actions(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @deny_wildcard_actions = val
      end

      def require_dlq(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @require_dlq = val
      end

      def require_log_retention(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @require_log_retention = val
      end

      def deny_public_storage(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @deny_public_storage = val
      end

      def build
        Model::StagePolicy.new(
          @stage,
          deny_wildcard_actions: @deny_wildcard_actions,
          require_dlq: @require_dlq,
          require_log_retention: @require_log_retention,
          deny_public_storage: @deny_public_storage
        )
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
