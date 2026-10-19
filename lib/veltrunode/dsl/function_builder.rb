# frozen_string_literal: true

require_relative 'base_builder'
require_relative 'permit_builder'
require_relative 'alarms_builder'
require_relative '../model/function'

module Veltrunode
  module DSL
    class FunctionBuilder < BaseBuilder
      def initialize(logical_name, runtime_default: nil, architecture_default: :x86_64)
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
      end

      def alarms(topic_or_opts = nil, **kwargs, &)
        opts = if topic_or_opts.is_a?(Hash)
                 topic_or_opts.merge(kwargs)
               elsif topic_or_opts
                 { topic: topic_or_opts }.merge(kwargs)
               else
                 kwargs
               end

        default_topic = opts[:topic]
        builder = AlarmsBuilder.new(default_topic: default_topic)

        if block_given?
          builder.instance_eval(&)
        else
          opts.each do |k, v|
            next if k == :topic

            builder.send(k, v) if builder.respond_to?(k)
          end
        end

        @alarms.concat(builder.build)
      end

      def build
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
          alarms: @alarms
        )
      end
    end
  end
end
