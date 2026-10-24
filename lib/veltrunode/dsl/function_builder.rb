# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'permit_builder'
require_relative 'alarms_builder'
require_relative 'logs_builder'
require_relative '../model/function'

module Veltrunode
  module DSL
    class FunctionBuilder < BaseBuilder
      def initialize(logical_name, runtime_default: nil, architecture_default: :x86_64, tracing_default: nil,
                     insights_default: nil, async_invoke_default: nil, alarms_default: nil)
        super()
        @logical_name = logical_name.to_s
        @handler = nil
        @runtime = runtime_default
        @architecture = architecture_default
        @memory = 128
        @timeout = 3
        @ephemeral_storage = 512
        @environment = {}
        @vpc_reference = nil
        @layers = []
        @mounts = []
        @iam_capabilities = []
        @concurrency = nil
        @logging = nil
        @alarms = []
        @alarms_builder = nil
        @alarms_disabled = alarms_default == false
        @alarms_default = alarms_default
        @subscription_filters = []
        @tracing = tracing_default
        @insights = insights_default
        @async_invoke = async_invoke_default
      end

      def handler(h)
        @handler = h.to_s
      end

      def runtime(r = nil, ruby: nil, python: nil, nodejs: nil, node: nil)
        if r
          str = r.to_s
          @runtime = str.start_with?('node') ? "nodejs#{str.sub(/^node(js)?/, '')}" : str
        elsif python
          py_str = python.to_s
          @runtime = "python#{py_str.sub(/^python/, '')}"
        elsif nodejs || node
          node_str = (nodejs || node).to_s
          @runtime = "nodejs#{node_str.sub(/^node(js)?/, '')}"
        elsif ruby
          ruby_str = ruby.to_s
          @runtime = "ruby#{ruby_str.sub(/^ruby/, '')}"
        end
      end

      def architecture(a)
        @architecture = a.to_sym
      end

      def memory(m)
        @memory = m.to_i
      end

      def timeout(t)
        @timeout = t.to_i
      end

      def ephemeral_storage(s)
        @ephemeral_storage = s.to_i
      end

      def environment(hash)
        @environment.merge!(hash)
      end

      def env_vars(hash)
        environment(hash)
      end

      def attach_layer(layer_name)
        @layers << layer_name.to_s
      end

      def mount(mount_name)
        @mounts << mount_name.to_s
      end

      def permit(&)
        return unless block_given?

        permit_builder = PermitBuilder.new
        permit_builder.instance_eval(&)
        @iam_capabilities.concat(permit_builder.capabilities)
      end

      def vpc_reference(ref)
        @vpc_reference = ref
      end

      def concurrency(c)
        @concurrency = c
      end

      def logging(l)
        @logging = l
        return unless l.is_a?(Hash)

        filters = l[:subscription_filters] || l['subscription_filters'] ||
                  l[:subscription_filter] || l['subscription_filter']
        return unless filters

        Array(filters).each do |f|
          if f.is_a?(Model::SubscriptionFilter)
            @subscription_filters << f
          elsif f.is_a?(Hash)
            builder = LogsBuilder.new
            builder.subscription_filter(f)
            @subscription_filters.concat(builder.subscription_filters)
          end
        end
      end

      def logs(retention_days_or_opts = nil, **kwargs, &)
        opts = if retention_days_or_opts.is_a?(Hash)
                 retention_days_or_opts.merge(kwargs)
               elsif retention_days_or_opts.is_a?(Numeric) || retention_days_or_opts.is_a?(String)
                 { retention_days: retention_days_or_opts.to_i }.merge(kwargs)
               else
                 kwargs
               end

        builder = LogsBuilder.new(retention_days: opts[:retention_days])

        if block_given?
          builder.instance_eval(&)
        elsif opts[:subscription_filter] || opts[:subscription_filters]
          filters = opts[:subscription_filters] || opts[:subscription_filter]
          filter_list = filters.is_a?(Array) ? filters : [filters]
          filter_list.each do |f|
            builder.subscription_filter(f)
          end
        end

        @logging = builder.to_h
        @subscription_filters.concat(builder.subscription_filters)
      end

      def alarms(topic_or_opts = nil, **kwargs, &)
        if topic_or_opts == false || kwargs[:enabled] == false
          @alarms_disabled = true
          @alarms_builder = nil
          @alarms = []
          return
        end

        @alarms_disabled = false

        if @alarms_builder.nil? && @alarms_default
          init_default = @alarms_default
          @alarms_default = nil
          apply_alarms_default(init_default)
        end

        opts = if topic_or_opts.is_a?(Hash)
                 topic_or_opts.merge(kwargs)
               elsif topic_or_opts.is_a?(Symbol) && Model::Alarm::PRESET_NAMES.include?(topic_or_opts)
                 { preset: topic_or_opts }.merge(kwargs)
               elsif topic_or_opts
                 { topic: topic_or_opts }.merge(kwargs)
               else
                 kwargs
               end

        @alarms_builder ||= AlarmsBuilder.new(default_topic: opts[:topic], function_timeout: @timeout)
        @alarms_builder.topic(opts[:topic]) if opts[:topic]
        @alarms_builder.preset(opts[:preset]) if opts[:preset]

        if block_given?
          @alarms_builder.instance_eval(&)
        else
          opts.each do |k, v|
            next if %i[topic preset enabled].include?(k)

            @alarms_builder.send(k, v) if @alarms_builder.respond_to?(k)
          end
        end

        @alarms = @alarms_builder.build
      end

      def tracing(mode_or_opts = nil, **kwargs)
        @tracing = if mode_or_opts.is_a?(Hash)
                     mode_or_opts.merge(kwargs)
                   elsif kwargs.empty?
                     mode_or_opts
                   else
                     { mode: mode_or_opts }.merge(kwargs)
                   end
      end

      def insights(enabled_or_opts = true, **kwargs) # rubocop:disable Style/OptionalBooleanParameter
        @insights = if enabled_or_opts.is_a?(Hash)
                      enabled_or_opts.merge(kwargs)
                    elsif kwargs.empty?
                      enabled_or_opts
                    else
                      { enabled: enabled_or_opts }.merge(kwargs)
                    end
      end

      def async_invoke(opts_or_arg = nil, **kwargs)
        @async_invoke = if opts_or_arg.is_a?(Hash)
                          opts_or_arg.merge(kwargs)
                        elsif opts_or_arg.nil?
                          kwargs.empty? ? nil : kwargs
                        elsif kwargs.empty?
                          opts_or_arg
                        else
                          kwargs.merge(enabled: opts_or_arg)
                        end
      end

      def build
        apply_alarms_default(@alarms_default) if !@alarms_disabled && @alarms_builder.nil? && @alarms_default

        if @alarms_builder
          @alarms_builder.function_timeout = @timeout
          @alarms = @alarms_builder.build
        end

        Model::Function.new(
          logical_name: @logical_name,
          handler: @handler,
          runtime: @runtime,
          architecture: @architecture,
          memory: @memory,
          timeout: @timeout,
          ephemeral_storage: @ephemeral_storage,
          environment: @environment,
          vpc_reference: @vpc_reference,
          layers: @layers,
          mounts: @mounts,
          iam_capabilities: @iam_capabilities,
          concurrency: @concurrency,
          logging: @logging,
          alarms: @alarms,
          subscription_filters: @subscription_filters,
          tracing: @tracing,
          insights: @insights,
          async_invoke: @async_invoke
        )
      end

      private

      def apply_alarms_default(default_cfg)
        if default_cfg.is_a?(Hash) && default_cfg[:block]
          alarms(default_cfg[:arg], **(default_cfg[:kwargs] || {}), &default_cfg[:block])
        elsif default_cfg.is_a?(Hash)
          alarms(**default_cfg)
        else
          alarms(default_cfg)
        end
      end
    end
  end
end
