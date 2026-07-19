# frozen_string_literal: true

module Veltrunode
  module DSLHelper
    def env(name)
      ENV.fetch(name, nil)
    end

    def ref(name)
      name.to_s
    end
  end

  class DSL
    include DSLHelper

    class LayerBuilder
      include DSLHelper

      def initialize(layer)
        @layer = layer
      end

      def bundle(lockfile: nil, without: [])
        @layer.lockfile = lockfile
        @layer.without = without
      end

      def include_gems(gems)
        # no-op
      end

      def build_on(os)
        @layer.build_on = os
      end

      def retain(latest:)
        @layer.retain = latest
      end
    end

    class EfsMountBuilder
      include DSLHelper

      def initialize(mount)
        @mount = mount
      end

      def existing_access_point(arn:)
        @mount.access_point_arn = arn
      end

      def access_point(arn:)
        @mount.access_point_arn = arn
      end

      def local_path(path)
        @mount.local_path = path
      end

      def expect_posix(uid:, gid:)
        @mount.uid = uid
        @mount.gid = gid
      end
    end

    class FunctionBuilder
      include DSLHelper

      def initialize(function)
        @function = function
      end

      def handler(h)
        @function.handler = h
      end

      def memory(m)
        @function.memory = m
      end

      def timeout(t)
        @function.timeout = t
      end

      def ephemeral_storage(s)
        @function.ephemeral_storage = s
      end

      def attach_layer(name)
        @function.attached_layers << name
      end

      def mount(name)
        @function.mounts << name
      end

      def permit(&)
        # Store capabilities
      end
    end

    class ScheduleBuilder
      include DSLHelper

      def initialize(schedule)
        @schedule = schedule
      end

      def target(t)
        @schedule.target = t
      end

      def cron(expr, timezone: 'UTC')
        @schedule.cron = expr
        @schedule.timezone = timezone
      end

      def rate(expr)
        @schedule.rate = expr
      end

      def at(expr)
        @schedule.at = expr
      end

      def input(source:)
        @schedule.input = source
      end

      def retry(maximum_attempts: nil, maximum_event_age: nil)
        @schedule.retry_policy = { attempts: maximum_attempts, age: maximum_event_age }
      end

      def dead_letter_queue(arn:)
        @schedule.dead_letter_queue = arn
      end
    end

    def self.evaluate(name, &)
      evaluator = new(name)
      evaluator.instance_eval(&) if block_given?
      evaluator.application
    end

    attr_reader :application

    def initialize(name)
      @application = Veltrunode::Application.new(name)
    end

    def aws(region: nil, account: nil, stage: nil)
      @application.region = region if region
      @application.account = account if account
      @application.stage = stage if stage
    end

    def runtime(ruby: nil, python: nil, node: nil, architecture: :x86_64)
      if ruby
        @application.runtime = "ruby#{ruby}"
      elsif python
        @application.runtime = "python#{python}"
      elsif node
        @application.runtime = "nodejs#{node}"
      end
      @application.architecture = architecture
    end

    def defaults(&)
      # no-op for now
    end

    def layer(name, &)
      l = Veltrunode::Layer.new(name)
      LayerBuilder.new(l).instance_eval(&) if block_given?
      @application.layers[name] = l
    end

    def efs_mount(name, &)
      m = Veltrunode::EfsMount.new(name)
      EfsMountBuilder.new(m).instance_eval(&) if block_given?
      @application.efs_mounts[name] = m
    end

    def function(name, &)
      f = Veltrunode::Function.new(name)
      f.runtime = @application.runtime
      f.architecture = @application.architecture
      FunctionBuilder.new(f).instance_eval(&) if block_given?
      @application.functions[name] = f
    end

    def schedule(name, &)
      s = Veltrunode::Schedule.new(name)
      ScheduleBuilder.new(s).instance_eval(&) if block_given?
      @application.schedules[name] = s
    end
  end
end
