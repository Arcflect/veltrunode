# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'efs_mount_builder'
require_relative 'permit_builder'
require_relative 'alarms_builder'
require_relative 'logs_builder'
require_relative 'function_url_builder'
require_relative '../model/function'

module Veltrunode
  module DSL
    class FunctionBuilder < BaseBuilder
      attr_reader :inline_mounts

      def initialize(logical_name, runtime_default: nil, architecture_default: :x86_64, tracing_default: nil,
                     insights_default: nil, async_invoke_default: nil, alarms_default: nil, event_sources_default: nil,
                     function_url_default: nil, mounts_default: nil)
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
        @inline_mounts = []
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
        @event_sources = []
        @function_url = function_url_default
        apply_event_sources_default(event_sources_default) if event_sources_default
        add_mount_entries(mounts_default) if mounts_default
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

      def mount(*args, **kwargs, &)
        if block_given?
          build_block_mount(args.first, **kwargs, &)
          return
        end

        if args.size == 2 && (args[0].is_a?(Symbol) || args[0].is_a?(String)) &&
           args[1].is_a?(String) && args[1].start_with?('/') && kwargs.empty?
          @mounts << { name: args[0].to_s, local_path: args[1] }
          return
        end

        if args.size == 1 && (args[0].is_a?(Symbol) || args[0].is_a?(String)) && !kwargs.empty?
          @mounts << normalize_mount_hash(kwargs.merge(name: args[0].to_s))
          return
        end

        add_mount_entries(args) unless args.empty?
        @mounts << normalize_mount_hash(kwargs) unless kwargs.empty?
      end
      alias mounts mount
      alias efs_mount mount
      alias efs_mounts mount

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

      def function_url(opts_or_arg = nil, **kwargs, &)
        if opts_or_arg == false || kwargs[:enabled] == false
          @function_url = nil
          return
        end

        init_opts = if opts_or_arg.is_a?(Hash)
                      opts_or_arg.merge(kwargs)
                    elsif opts_or_arg.is_a?(Symbol) || opts_or_arg.is_a?(String)
                      kwargs.merge(auth_type: opts_or_arg)
                    else
                      kwargs
                    end

        if block_given?
          builder = FunctionUrlBuilder.new(**init_opts)
          builder.instance_eval(&)
          @function_url = builder.build
        elsif opts_or_arg.is_a?(Model::FunctionUrl)
          @function_url = opts_or_arg
        elsif init_opts.empty?
          @function_url = Model::FunctionUrl.from(opts_or_arg.nil? || opts_or_arg)
        else
          @function_url = Model::FunctionUrl.from(init_opts)
        end
      end

      def event_source(type_or_opts = nil, **kwargs, &)
        if type_or_opts == false || kwargs[:enabled] == false
          @event_sources = []
          return
        end

        if type_or_opts.is_a?(Model::EventSource)
          @event_sources << type_or_opts
          return
        end

        opts = kwargs.dup
        opts.merge!(type_or_opts) if type_or_opts.is_a?(Hash)

        if opts.key?(:sqs)
          @event_sources << build_keyed_event_source(:sqs, opts.delete(:sqs), opts, :queue, &)
          return
        elsif opts.key?(:sns)
          @event_sources << build_keyed_event_source(:sns, opts.delete(:sns), opts, :topic, &)
          return
        elsif opts.key?(:s3)
          @event_sources << build_keyed_event_source(:s3, opts.delete(:s3), opts, :bucket, &)
          return
        elsif opts.key?(:dynamodb_stream)
          @event_sources << build_keyed_event_source(:dynamodb_stream, opts.delete(:dynamodb_stream), opts, :stream, &)
          return
        elsif opts.key?(:kinesis_stream)
          @event_sources << build_keyed_event_source(:kinesis_stream, opts.delete(:kinesis_stream), opts, :stream, &)
          return
        elsif opts.key?(:kinesis)
          @event_sources << build_keyed_event_source(:kinesis_stream, opts.delete(:kinesis), opts, :stream, &)
          return
        elsif opts.key?(:msk)
          @event_sources << build_keyed_event_source(:msk, opts.delete(:msk), opts, :cluster, &)
          return
        elsif opts.key?(:kafka)
          @event_sources << build_keyed_event_source(:msk, opts.delete(:kafka), opts, :cluster, &)
          return
        elsif opts.key?(:mq)
          @event_sources << build_keyed_event_source(:mq, opts.delete(:mq), opts, :broker, &)
          return
        elsif opts.key?(:amazon_mq)
          @event_sources << build_keyed_event_source(:mq, opts.delete(:amazon_mq), opts, :broker, &)
          return
        elsif opts.key?(:activemq)
          @event_sources << build_keyed_event_source(:mq, opts.delete(:activemq), opts, :broker, &)
          return
        elsif opts.key?(:rabbitmq)
          @event_sources << build_keyed_event_source(:mq, opts.delete(:rabbitmq), opts, :broker, &)
          return
        elsif opts.key?(:rule)
          @event_sources << build_keyed_event_source(:rule, opts.delete(:rule), opts, :name, &)
          return
        elsif opts.key?(:eventbridge)
          @event_sources << build_keyed_event_source(:rule, opts.delete(:eventbridge), opts, :name, &)
          return
        end

        type = resolve_event_source_type(type_or_opts, opts)
        builder = EventSourceBuilder.new(type, **opts)
        builder.instance_eval(&) if block_given?
        @event_sources << builder.build
      end
      alias event_sources event_source

      def rule(name_or_opts = nil, **kwargs, &)
        if name_or_opts == false
          @event_sources.reject!(&:rule?)
          return
        end

        if name_or_opts.is_a?(Model::EventSource)
          @event_sources << name_or_opts
          return
        end

        opts = kwargs.dup
        if name_or_opts.is_a?(Hash)
          opts.merge!(name_or_opts)
        elsif name_or_opts
          opts[:name] = name_or_opts
        end

        builder = EventSourceBuilder.new(:rule, **opts)
        builder.instance_eval(&) if block_given?
        @event_sources << builder.build
      end
      alias rules rule

      def kinesis_stream(stream_or_opts = nil, **, &)
        if stream_or_opts == false
          @event_sources.reject!(&:kinesis_stream?)
          return
        end

        event_source(:kinesis_stream, kinesis_stream: stream_or_opts, **, &)
      end

      def msk(cluster_or_opts = nil, **, &)
        if cluster_or_opts == false
          @event_sources.reject!(&:msk?)
          return
        end

        if cluster_or_opts.nil?
          event_source(:msk, **, &)
        else
          event_source(:msk, msk: cluster_or_opts, **, &)
        end
      end
      alias kafka msk

      def mq(broker_or_opts = nil, **, &)
        if broker_or_opts == false
          @event_sources.reject!(&:mq?)
          return
        end

        if broker_or_opts.nil?
          event_source(:mq, **, &)
        else
          event_source(:mq, mq: broker_or_opts, **, &)
        end
      end
      alias amazon_mq mq

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
          async_invoke: @async_invoke,
          event_sources: @event_sources,
          function_url: @function_url
        )
      end

      private

      def build_block_mount(name, **, &)
        builder = EfsMountBuilder.new(name, **)
        builder.instance_eval(&)
        if builder.inline_mount_definition?
          built = builder.build
          @inline_mounts << built
          @mounts << { name: built.symbolic_name, local_path: built.local_path }
        elsif builder.local_path_value
          @mounts << { name: name.to_s, local_path: builder.local_path_value }
        else
          @mounts << name.to_s
        end
      end

      def add_mount_entries(entries)
        list = entries.is_a?(Array) ? entries : [entries]
        list.each do |entry|
          case entry
          when Array
            add_mount_entries(entry)
          when Hash
            @mounts << normalize_mount_hash(entry)
          when Model::EfsMount
            @inline_mounts << entry
            @mounts << { name: entry.symbolic_name, local_path: entry.local_path }
          when nil, false
            next
          else
            @mounts << entry.to_s
          end
        end
      end

      def normalize_mount_hash(hash)
        normalized = {}
        name_val = hash[:name] || hash['name'] || hash[:symbolic_name] || hash['symbolic_name'] ||
                   hash[:mount] || hash['mount'] || hash[:efs_mount] || hash['efs_mount'] ||
                   hash[:access_point] || hash['access_point']
        path_val = hash[:local_path] || hash['local_path'] ||
                   hash[:local_mount_path] || hash['local_mount_path'] ||
                   hash[:path] || hash['path']
        arn_val = hash[:arn] || hash['arn'] || hash[:access_point_source] || hash['access_point_source']

        normalized[:name] = name_val.to_s if name_val
        normalized[:local_path] = path_val.to_s if path_val
        normalized[:arn] = arn_val if arn_val

        if name_val && arn_val && path_val
          @inline_mounts << Model::EfsMount.new(
            symbolic_name: name_val.to_s,
            access_point_source: arn_val,
            local_path: path_val.to_s
          )
        end

        normalized
      end

      def apply_event_sources_default(default_cfg)
        list = default_cfg.is_a?(Array) ? default_cfg : [default_cfg]
        list.each do |cfg|
          event_source(cfg)
        end
      end

      def build_keyed_event_source(type, val, extra_opts, default_key, &)
        merged_opts = if val.is_a?(Hash) && !cfn_intrinsic_hash?(val)
                        val.merge(extra_opts)
                      else
                        extra_opts.merge(default_key => val)
                      end
        builder = EventSourceBuilder.new(type, **merged_opts)
        builder.instance_eval(&) if block_given?
        builder.build
      end

      def resolve_event_source_type(type_or_opts, opts)
        return type_or_opts if type_or_opts.is_a?(Symbol) || type_or_opts.is_a?(String)
        return :rule if opts.key?(:pattern) || opts.key?(:event_pattern) || opts.key?(:bus) || opts.key?(:event_bus)
        return :msk if opts.key?(:cluster) || opts.key?(:cluster_arn)
        return :mq if opts.key?(:broker) || opts.key?(:broker_arn)
        return :sns if opts.key?(:topic) || opts.key?(:topic_arn)
        return :s3 if opts.key?(:bucket)
        return :dynamodb_stream if opts.key?(:stream) || opts.key?(:stream_arn)

        :sqs
      end

      def cfn_intrinsic_hash?(hash)
        hash.key?('Ref') || hash.key?(:Ref) || hash.key?(:ref) || hash.key?('ref') ||
          hash.keys.any? { |k| k.to_s.start_with?('Fn::') }
      end

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
