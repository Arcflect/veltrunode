require "thor"
require "json"
require_relative "generator"
require_relative "runner"

module Veltrunode
  class CLI < Thor
    class << self
      def start(given_args = ARGV, config = {})
        if given_args[0] == "invoke" && given_args[1] == "local"
          given_args = ["invoke_local"] + given_args[2..]
        end
        super(given_args, config)
      end
    end

    desc "init", "Initialize a new Veltrunode project"
    def init
      Veltrunode::Generator.run(".")
    end

    desc "validate", "Validate Veltrunodefile schema and settings"
    def validate
      unless File.exist?("Veltrunodefile")
        raise Veltrunode::Error, "Veltrunodefile not found."
      end

      Veltrunode.reset!
      load "./Veltrunodefile"
      app = Veltrunode.last_application
      unless app
        raise Veltrunode::Error, "No application defined in Veltrunodefile."
      end

      errors = []
      if app.name.nil? || app.name.strip.empty?
        errors << "Application name is required"
      end

      app.functions.each do |func_name, func|
        if func.handler.nil? || !func.handler.include?(".")
          errors << "Function '#{func_name}' handler must be in 'file.method' format"
        end
      end

      if errors.empty?
        puts "Validation successful!"
      else
        raise Veltrunode::Error, "Validation failed:\n- #{errors.join("\n- ")}"
      end
    end

    desc "invoke local NAME", "Simulate executing a Lambda function locally"
    method_option :event, type: :string, desc: "Path to JSON file containing event data"
    def invoke_local(name)
      unless File.exist?("Veltrunodefile")
        raise Veltrunode::Error, "Veltrunodefile not found. Run 'veltrunode init' first."
      end

      Veltrunode.reset!
      load "./Veltrunodefile"
      app = Veltrunode.last_application
      unless app
        raise Veltrunode::Error, "No application defined in Veltrunodefile."
      end

      function = app.functions[name.to_sym]
      unless function
        raise Veltrunode::Error, "Function '#{name}' not found in Veltrunodefile."
      end

      event_data = {}
      if options[:event]
        unless File.exist?(options[:event])
          raise Veltrunode::Error, "Event file not found: #{options[:event]}"
        end
        event_data = JSON.parse(File.read(options[:event]))
      end

      Veltrunode::Runner.run(function, event_data)
    end
  end
end
