# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'
require_relative 'runner/lambda_context'
require_relative 'runner/execution_result'

module Veltrunode
  class Runner
    class TimeoutError < Veltrunode::Error; end

    def self.run(function, event_data = {}, application: nil, source_dir: nil)
      new(function, event_data, application: application, source_dir: source_dir).execute
    end

    def initialize(function, event_data = {}, application: nil, source_dir: nil)
      @function = function
      @event_data = event_data || {}
      @application = application
      @source_dir = source_dir || Dir.pwd
    end

    def execute
      validate_handler_format!

      file_part, method_name = @function.handler.split('.', 2)
      runtime = @function.runtime || @application&.runtime || 'ruby'
      timeout_sec = (@function.timeout || 3).to_i
      memory_size = (@function.memory || 128).to_i

      context = LambdaContext.new(
        function_name: @function.logical_name,
        memory_limit_in_mb: memory_size,
        timeout: timeout_sec
      )

      env_vars = build_environment
      warnings = collect_warnings

      raw_result = execute_with_timeout(timeout_sec, env_vars) do
        dispatch_execution(runtime, file_part, method_name, context, env_vars)
      end

      build_execution_result(raw_result, memory_size, warnings)
    end

    private

    def validate_handler_format!
      handler_str = @function.handler
      return if handler_str&.include?('.')

      raise Veltrunode::Error, "Invalid handler format: '#{handler_str}'. Expected 'file.method'"
    end

    def collect_warnings
      warnings = []
      if @function.mounts && !@function.mounts.empty?
        warnings << 'EFS mount simulation is skipped in local execution (local limitation).'
      end
      warnings
    end

    def execute_with_timeout(timeout_sec, env_vars)
      @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = nil

      begin
        Timeout.timeout(timeout_sec) do
          with_environment(env_vars) do
            result = yield
          end
        end
      rescue Timeout::Error
        raise TimeoutError, "Function '#{@function.logical_name}' timed out after #{timeout_sec} seconds."
      end

      @end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result
    end

    def build_execution_result(raw_result, memory_size, warnings)
      duration_ms = (@end_time - @start_time) * 1000.0

      ExecutionResult.new(
        result: raw_result,
        duration_ms: duration_ms,
        memory_size_mb: memory_size,
        function_name: @function.logical_name,
        warnings: warnings
      )
    end

    def dispatch_execution(runtime, file_part, method_name, context, env_vars)
      if runtime.start_with?('ruby')
        execute_ruby(file_part, method_name, context)
      elsif runtime.start_with?('python')
        execute_python(file_part, method_name, context, env_vars)
      elsif runtime.start_with?('node')
        execute_node(file_part, method_name, context, env_vars)
      else
        raise Veltrunode::Error, "Unsupported runtime for local execution: #{runtime}"
      end
    end

    def execute_ruby(file_part, method_name, context)
      rb_file = File.expand_path("#{file_part}.rb", @source_dir)
      raise Veltrunode::Error, "Ruby file not found: #{rb_file}" unless File.exist?(rb_file)

      load rb_file

      target_method = resolve_ruby_method(method_name, rb_file)
      call_handler_method(target_method, @event_data, context)
    end

    def resolve_ruby_method(method_name, rb_file)
      sym = method_name.to_sym
      raise Veltrunode::Error, "Handler method '#{method_name}' not defined in #{rb_file}" unless respond_to?(sym, true)

      m = method(sym)
      loc = m.source_location
      return m if loc && File.expand_path(loc[0]) == File.expand_path(rb_file)

      raise Veltrunode::Error, "Handler method '#{method_name}' not defined in #{rb_file}"
    end

    def call_handler_method(method_obj, event, context)
      params = method_obj.parameters
      if params.any? { |type, _| %i[key keyreq keyrest].include?(type) }
        invoke_keyword_handler(method_obj, params, event, context)
      else
        invoke_positional_handler(method_obj, event, context)
      end
    rescue TimeoutError
      raise
    rescue StandardError => e
      raise Veltrunode::Error, "Failed to execute Ruby handler: #{e.message}"
    end

    def invoke_keyword_handler(method_obj, params, event, context)
      has_keyrest = params.any? { |param| param[0] == :keyrest }
      key_names = params.filter_map { |type, name| name if %i[key keyreq].include?(type) }

      kwargs = {}
      kwargs[:event] = event if has_keyrest || key_names.include?(:event)
      kwargs[:context] = context if has_keyrest || key_names.include?(:context)

      args = build_positional_args(params, event, context)
      if kwargs.empty?
        method_obj.call(*args)
      else
        method_obj.call(*args, **kwargs)
      end
    end

    def build_positional_args(params, event, context)
      positional_count = params.count { |param| %i[req opt].include?(param[0]) }
      has_rest = params.any? { |param| param[0] == :rest }

      if has_rest || positional_count >= 2
        [event, context]
      elsif positional_count == 1
        [event]
      else
        []
      end
    end

    def invoke_positional_handler(method_obj, event, context)
      args = build_positional_args(method_obj.parameters, event, context)
      method_obj.call(*args)
    end

    def execute_python(file_part, method_name, context, env_vars)
      module_name = file_part.tr('/', '.')
      event_json = JSON.generate(@event_data)
      context_json = JSON.generate(context.to_h)

      py_code = <<~PYTHON
        import importlib, json, sys
        sys.path.insert(0, '.')
        try:
            module_name = sys.argv[1]
            method_name = sys.argv[2]
            event = json.loads(sys.argv[3])
            context = json.loads(sys.argv[4])
            handler_module = importlib.import_module(module_name)
            method = getattr(handler_module, method_name)
            res = method(event, context)
            print(json.dumps(res))
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
      PYTHON

      stdout, stderr, status = Open3.capture3(
        env_vars,
        'python3',
        '-c',
        py_code,
        module_name,
        method_name,
        event_json,
        context_json,
        chdir: @source_dir
      )
      raise Veltrunode::Error, "Python execution failed: #{stderr.strip}" unless status.success?

      parse_subprocess_output(stdout)
    end

    def execute_node(file_part, method_name, context, env_vars)
      event_json = JSON.generate(@event_data)
      context_json = JSON.generate(context.to_h)
      node_file = File.expand_path(file_part, @source_dir)

      node_code = <<~JS
        const path = require('path');
        try {
          const filePath = path.resolve(process.argv[2]);
          const methodName = process.argv[3];
          const event = JSON.parse(process.argv[4]);
          const context = JSON.parse(process.argv[5]);
          const handlerModule = require(filePath);
          const method = handlerModule[methodName];
          if (!method) {
            console.error("Method '" + methodName + "' not found on module.");
            process.exit(1);
          }
          Promise.resolve(method(event, context)).then(res => {
            console.log(JSON.stringify(res));
          }).catch(err => {
            console.error(err);
            process.exit(1);
          });
        } catch (e) {
          console.error(e);
          process.exit(1);
        }
      JS

      stdout, stderr, status = Open3.capture3(
        env_vars,
        'node',
        '-e',
        node_code,
        node_file,
        method_name,
        event_json,
        context_json,
        chdir: @source_dir
      )
      raise Veltrunode::Error, "Node.js execution failed: #{stderr.strip}" unless status.success?

      parse_subprocess_output(stdout)
    end

    def parse_subprocess_output(stdout)
      JSON.parse(stdout.strip)
    rescue JSON::ParserError
      stdout.strip
    end

    def build_environment
      region = @application&.region || 'ap-northeast-1'
      stage = @application&.stage || 'dev'
      app_name = @application&.name || 'veltrunode'

      env = {
        'AWS_LAMBDA_FUNCTION_NAME' => @function.logical_name.to_s,
        'AWS_LAMBDA_FUNCTION_VERSION' => '$LATEST',
        'AWS_LAMBDA_FUNCTION_MEMORY_SIZE' => (@function.memory || 128).to_s,
        'AWS_REGION' => region.to_s,
        'AWS_DEFAULT_REGION' => region.to_s,
        'LAMBDA_TASK_ROOT' => File.expand_path(@source_dir).to_s,
        'LAMBDA_RUNTIME_DIR' => '/var/runtime',
        '_HANDLER' => @function.handler.to_s,
        'STAGE' => stage.to_s,
        'VELTRUNODE_APP' => app_name.to_s
      }

      if @function.environment.is_a?(Hash)
        @function.environment.each do |k, v|
          env[k.to_s] = v.to_s
        end
      end

      env
    end

    def with_environment(env)
      old_env = {}
      env.each do |k, v|
        old_env[k] = ENV.fetch(k, nil)
        ENV[k] = v
      end
      begin
        yield
      ensure
        old_env.each do |k, v|
          if v.nil?
            ENV.delete(k)
          else
            ENV[k] = v
          end
        end
      end
    end
  end
end
