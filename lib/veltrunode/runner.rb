# frozen_string_literal: true

require 'json'
require 'open3'

module Veltrunode
  class Runner
    def self.run(function, event_data)
      new(function, event_data).execute
    end

    def initialize(function, event_data)
      @function = function
      @event_data = event_data || {}
    end

    def execute
      handler_str = @function.handler
      unless handler_str&.include?('.')
        raise Veltrunode::Error, "Invalid handler format: '#{handler_str}'. Expected 'file.method'"
      end

      file_part, method_name = handler_str.split('.', 2)
      runtime = @function.runtime || 'ruby'

      if runtime.start_with?('ruby')
        execute_ruby(file_part, method_name)
      elsif runtime.start_with?('python')
        execute_python(file_part, method_name)
      elsif runtime.start_with?('node')
        execute_node(file_part, method_name)
      else
        raise Veltrunode::Error, "Unsupported runtime for local execution: #{runtime}"
      end
    end

    private

    def execute_ruby(file_part, method_name)
      rb_file = "#{file_part}.rb"
      raise Veltrunode::Error, "Ruby file not found: #{rb_file}" unless File.exist?(rb_file)

      # Load the file inside a clean scope or main object
      load File.expand_path(rb_file)

      # Invoke the method
      unless respond_to?(method_name.to_sym, true) || Kernel.respond_to?(method_name.to_sym, true)
        raise Veltrunode::Error, "Handler method '#{method_name}' not defined in #{rb_file}"
      end

      # Ruby handlers can accept keywords or positional args.
      # Lambda standard is keyword args for event/context or positional.
      # Let's inspect the method arity or just try calling it.
      method_obj = begin
        method(method_name.to_sym)
      rescue StandardError
        Kernel.method(method_name.to_sym)
      end

      # Check if it accepts keyword arguments or positional arguments
      begin
        res = method_obj.call(event: @event_data, context: {})
        puts JSON.pretty_generate(res)
        res
      rescue ArgumentError
        # Fallback to positional if keywords fail
        begin
          res = method_obj.call(@event_data, {})
          puts JSON.pretty_generate(res)
          res
        rescue StandardError => e2
          raise Veltrunode::Error, "Failed to execute Ruby handler: #{e2.message}"
        end
      rescue StandardError => e
        raise Veltrunode::Error, "Failed to execute Ruby handler: #{e.message}"
      end
    end

    def execute_python(file_part, method_name)
      # Convert file path to module notation: e.g. functions/hello -> functions.hello
      module_name = file_part.gsub('/', '.')
      event_json = JSON.generate(@event_data)

      py_code = <<~PYTHON
        import json, sys
        sys.path.append('.')
        try:
            import #{module_name} as handler_module
            method = getattr(handler_module, '#{method_name}')
            event = json.loads(sys.argv[1])
            res = method(event, {})
            print(json.dumps(res))
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
      PYTHON

      stdout, stderr, status = Open3.capture3('python3', '-c', py_code, event_json)
      raise Veltrunode::Error, "Python execution failed: #{stderr.strip}" unless status.success?

      begin
        parsed = JSON.parse(stdout.strip)
        puts JSON.pretty_generate(parsed)
        parsed
      rescue JSON::ParserError
        puts stdout
        stdout
      end
    end

    def execute_node(file_part, method_name)
      event_json = JSON.generate(@event_data)
      node_file = File.expand_path("./#{file_part}")

      node_code = <<~JS
        const path = require('path');
        try {
          const handlerModule = require('#{node_file}');
          const method = handlerModule['#{method_name}'];
          if (!method) {
            console.error("Method '#{method_name}' not found on module.");
            process.exit(1);
          }
          const event = JSON.parse(process.argv[2]);
          Promise.resolve(method(event, {})).then(res => {
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

      stdout, stderr, status = Open3.capture3('node', '-e', node_code, event_json)
      raise Veltrunode::Error, "Node.js execution failed: #{stderr.strip}" unless status.success?

      begin
        parsed = JSON.parse(stdout.strip)
        puts JSON.pretty_generate(parsed)
        parsed
      rescue JSON::ParserError
        puts stdout
        stdout
      end
    end
  end
end
