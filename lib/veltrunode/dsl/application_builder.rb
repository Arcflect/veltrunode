# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'layer_builder'
require_relative 'efs_mount_builder'
require_relative 'function_builder'
require_relative 'schedule_builder'
require_relative 'logs_builder'
require_relative 'dashboard_builder'
require_relative '../model/application'
require_relative '../model/stage_policy'

module Veltrunode
  module DSL
    class ApplicationBuilder < BaseBuilder
      def initialize(name, cache: nil, cache_config: nil)
        super()
        @name = name.to_s
        @region = 'ap-northeast-1'
        @stage = 'dev'
        @account_constraint = nil
        @artifact_bucket = nil
        @cache_config = cache || cache_config || {}
        @runtime_defaults = {}
        @function_builders = []
        @layer_builders = []
        @schedule_builders = []
        @efs_mount_builders = []
        @security_group_builders = []
        @policies = []
        @tags = {}
        @dashboard_builder = nil
      end

      def cache(config = nil, remote: nil, &)
        if block_given?
          builder = CacheBuilder.new
          builder.instance_eval(&)
          @cache_config = builder.build
        elsif config
          @cache_config = config
        elsif remote
          @cache_config = { remote: remote }
        end
      end

      def aws(region: nil, account: nil, account_constraint: nil, artifact_bucket: nil, bucket: nil)
        @region = region.to_s if region
        @account_constraint = (account || account_constraint)&.to_s
        @artifact_bucket = (artifact_bucket || bucket)&.to_s
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
        @runtime_defaults[:tracing] = defaults_builder.tracing_config if defaults_builder.tracing_config
        @runtime_defaults[:insights] = defaults_builder.insights_config if defaults_builder.insights_config
        @runtime_defaults[:async_invoke] = defaults_builder.async_invoke_config if defaults_builder.async_invoke_config
        @runtime_defaults[:alarms] = defaults_builder.alarms_config if defaults_builder.alarms_config
        if defaults_builder.event_sources_config
          @runtime_defaults[:event_sources] = defaults_builder.event_sources_config
        end
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

      def managed_access_point(name, file_system_id = nil, **, &)
        builder = EfsMountBuilder.new(name)
        builder.managed_access_point(file_system_id, **, &)
        @efs_mount_builders << builder
      end

      def security_group_helper(name = nil, vpc_id: nil, **, &)
        builder = if name.is_a?(Hash)
                    opts = name
                    target_name = :default
                    target_vpc_id = opts[:vpc_id] || opts['vpc_id']
                    extra_opts = opts.reject { |k, _| k.to_s == 'vpc_id' }
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: target_vpc_id, **extra_opts)
                  else
                    target_name = name || :default
                    SecurityGroupHelperBuilder.new(target_name, vpc_id: vpc_id, **)
                  end
        builder.instance_eval(&) if block_given?
        @security_group_builders << builder
        builder
      end
      alias efs_security_groups security_group_helper
      alias efs_security_group security_group_helper

      def function(name, tracing: nil, insights: nil, async_invoke: nil, alarms: nil,
                   event_source: nil, event_sources: nil, **, &)
        alarms_cfg = alarms.nil? ? @runtime_defaults[:alarms] : alarms
        es_cfg = event_source || event_sources || @runtime_defaults[:event_sources]
        builder = FunctionBuilder.new(
          name,
          runtime_default: resolve_default_runtime,
          architecture_default: @runtime_defaults[:architecture] || :x86_64,
          tracing_default: tracing || @runtime_defaults[:tracing],
          insights_default: insights || @runtime_defaults[:insights],
          async_invoke_default: async_invoke || @runtime_defaults[:async_invoke],
          alarms_default: alarms_cfg,
          event_sources_default: es_cfg
        )
        builder.instance_eval(&) if block_given?
        @function_builders << builder
      end

      def schedule(name, &)
        builder = ScheduleBuilder.new(name)
        builder.instance_eval(&) if block_given?
        @schedule_builders << builder
      end

      def stage_policy(stage, pack: nil, deny_wildcard_actions: nil, require_dlq: nil,
                       require_log_retention: nil, deny_public_storage: nil, &)
        builder = StagePolicyBuilder.new(
          stage,
          pack: pack,
          deny_wildcard_actions: deny_wildcard_actions,
          require_dlq: require_dlq,
          require_log_retention: require_log_retention,
          deny_public_storage: deny_public_storage
        )
        builder.instance_eval(&) if block_given?
        @policies << builder.build
      end
      alias policy stage_policy
      alias custom_policy stage_policy

      def policy_pack(name = :production, stage: nil, **, &)
        target_stage = stage || @stage || name.to_s
        stage_policy(target_stage, pack: name, **, &)
      end

      def dashboard(arg = true, name: nil, title: nil, period: nil, enabled: true, **, &) # rubocop:disable Style/OptionalBooleanParameter
        if arg == false
          @dashboard_builder = nil
          return
        end

        opts = {}
        target_name = :default

        if arg.is_a?(Hash)
          opts = arg
        elsif arg.is_a?(Symbol) || (arg.is_a?(String) && !arg.empty? && arg != 'true' && arg != 'false')
          target_name = arg
        end

        target_name = name || opts[:name] || target_name
        target_title = title || opts[:title]
        target_period = period || opts[:period]
        target_enabled = enabled && (opts[:enabled].nil? || opts[:enabled])

        unless target_enabled
          @dashboard_builder = nil
          return
        end

        builder = DashboardBuilder.new(target_name, title: target_title, period: target_period, enabled: true)
        builder.instance_eval(&) if block_given?
        @dashboard_builder = builder
      end

      def build
        layers = @layer_builders.map(&:build)
        mounts = @efs_mount_builders.map(&:build)
        functions = @function_builders.map(&:build)
        schedules = @schedule_builders.map(&:build)

        mount_sgs = mounts.map(&:security_group_helper).compact
        explicit_sgs = @security_group_builders.map(&:build)
        all_sgs = (explicit_sgs + mount_sgs).uniq(&:symbolic_name)

        Model::Application.new(
          name: @name,
          region: @region,
          stage: @stage,
          account_constraint: @account_constraint,
          artifact_bucket: @artifact_bucket,
          cache: @cache_config,
          runtime_defaults: @runtime_defaults,
          functions: functions,
          layers: layers,
          schedules: schedules,
          mounts: mounts,
          security_groups: all_sgs,
          policies: @policies,
          tags: @tags,
          dashboard: @dashboard_builder&.build
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
      def initialize(stage, pack: nil, deny_wildcard_actions: nil, require_dlq: nil,
                     require_log_retention: nil, deny_public_storage: nil)
        super()
        @stage = stage
        @pack_name = pack&.to_s

        base_rules = if pack
                       Model::PolicyPack.builtin(pack).to_rules_hash
                     else
                       {
                         deny_wildcard_actions: false,
                         require_dlq: false,
                         require_log_retention: false,
                         deny_public_storage: false
                       }
                     end

        @deny_wildcard_actions = deny_wildcard_actions.nil? ? base_rules[:deny_wildcard_actions] : deny_wildcard_actions
        @require_dlq = require_dlq.nil? ? base_rules[:require_dlq] : require_dlq
        @require_log_retention = require_log_retention.nil? ? base_rules[:require_log_retention] : require_log_retention
        @deny_public_storage = deny_public_storage.nil? ? base_rules[:deny_public_storage] : deny_public_storage
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
          deny_public_storage: @deny_public_storage,
          pack_name: @pack_name
        )
      end
    end

    class DefaultsBuilder < BaseBuilder
      attr_reader :logs_config, :tags_config, :tracing_config, :insights_config, :async_invoke_config, :alarms_config,
                  :event_sources_config

      def initialize
        super
        @logs_config = nil
        @tags_config = {}
        @tracing_config = nil
        @insights_config = nil
        @async_invoke_config = nil
        @alarms_config = nil
        @event_sources_config = nil
      end

      def alarms(arg = nil, **kwargs, &block)
        @alarms_config = if block_given?
                           { arg: arg, kwargs: kwargs, block: block }
                         elsif arg.is_a?(Hash)
                           arg.merge(kwargs)
                         elsif arg
                           { preset: arg }.merge(kwargs)
                         else
                           kwargs
                         end
      end

      def logs(retention_days: nil, **, &)
        builder = LogsBuilder.new(retention_days: retention_days)
        builder.instance_eval(&) if block_given?
        cfg = builder.to_h
        cfg['retention_days'] ||= retention_days.to_i if retention_days
        @logs_config = cfg
      end

      def tracing(mode_or_opts = nil, **kwargs)
        @tracing_config = if mode_or_opts.is_a?(Hash)
                            mode_or_opts.merge(kwargs)
                          elsif kwargs.empty?
                            mode_or_opts
                          else
                            { mode: mode_or_opts }.merge(kwargs)
                          end
      end

      def insights(enabled_or_opts = true, **kwargs) # rubocop:disable Style/OptionalBooleanParameter
        @insights_config = if enabled_or_opts.is_a?(Hash)
                             enabled_or_opts.merge(kwargs)
                           elsif kwargs.empty?
                             enabled_or_opts
                           else
                             { enabled: enabled_or_opts }.merge(kwargs)
                           end
      end

      def async_invoke(opts_or_arg = nil, **kwargs)
        @async_invoke_config = if opts_or_arg.is_a?(Hash)
                                 opts_or_arg.merge(kwargs)
                               elsif opts_or_arg.nil?
                                 kwargs.empty? ? nil : kwargs
                               elsif kwargs.empty?
                                 opts_or_arg
                               else
                                 kwargs.merge(enabled: opts_or_arg)
                               end
      end

      def event_source(type_or_opts = nil, **kwargs, &)
        @event_sources_config ||= []
        opts = kwargs.dup
        opts.merge!(type_or_opts) if type_or_opts.is_a?(Hash)

        if opts.key?(:sqs)
          sqs_val = opts.delete(:sqs)
          sqs_opts = sqs_val.is_a?(Hash) ? sqs_val.merge(opts) : opts.merge(queue: sqs_val)
          builder = EventSourceBuilder.new(:sqs, **sqs_opts)
          builder.instance_eval(&) if block_given?
          @event_sources_config << builder.build
          return
        elsif opts.key?(:sns)
          sns_val = opts.delete(:sns)
          sns_opts = sns_val.is_a?(Hash) ? sns_val.merge(opts) : opts.merge(topic: sns_val)
          builder = EventSourceBuilder.new(:sns, **sns_opts)
          builder.instance_eval(&) if block_given?
          @event_sources_config << builder.build
          return
        end

        type = if type_or_opts.is_a?(Symbol) || type_or_opts.is_a?(String)
                 type_or_opts
               elsif opts.key?(:topic) || opts.key?(:topic_arn)
                 :sns
               else
                 :sqs
               end
        builder = EventSourceBuilder.new(type, **opts)
        builder.instance_eval(&) if block_given?
        @event_sources_config << builder.build
      end
      alias event_sources event_source

      def tags(hash = {})
        @tags_config.merge!(hash)
      end
    end
  end
end
