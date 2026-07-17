# frozen_string_literal: true

require 'json'

module Veltrunode
  class CLI
    # 終了コード体系の定義
    EXIT_SUCCESS = 0
    EXIT_INVALID_INPUT = 2
    EXIT_VALIDATION_FAILED = 3
    EXIT_AWS_AUTH_FAILED = 4
    EXIT_BUILD_FAILED = 5
    EXIT_PLAN_FAILED = 6
    EXIT_DEPLOY_FAILED = 7
    EXIT_POLICY_VIOLATION = 8

    def self.start(argv)
      exit_code = Router.run(argv)
      exit exit_code
    end

    class Router
      def self.run(argv)
        new(argv).run
      end

      def initialize(argv)
        @argv = argv.dup
        @options = {
          format: :text,
          file: 'Veltrunodefile'
        }
      end

      def run
        parse_global_options!

        if @options[:version]
          print_version
          return EXIT_SUCCESS
        end

        if @options[:help] || @argv.empty?
          print_help
          return EXIT_SUCCESS
        end

        # コマンドのディスパッチ
        if match_command?('init')
          execute_init
        elsif match_command?('validate')
          execute_validate
        elsif match_command?('build')
          execute_build
        elsif match_command?('plan')
          execute_plan
        elsif match_command?('deploy')
          execute_deploy
        elsif match_command?('invoke local')
          execute_invoke_local
        elsif match_command?('destroy')
          execute_destroy
        elsif match_command?('efs verify')
          execute_efs_verify
        elsif match_command?('layer inspect')
          execute_layer_inspect
        elsif match_command?('schedule preview')
          execute_schedule_preview
        else
          handle_unknown_command(@argv.join(' '))
        end
      rescue StandardError => e
        exit_code = e.respond_to?(:exit_code) ? e.exit_code : EXIT_INVALID_INPUT
        handle_error(e.message, exit_code)
      end

      private

      def parse_global_options!
        # --format オプションの抽出
        if (idx = @argv.index('--format'))
          if (val = @argv[idx + 1])
            @options[:format] = val.to_sym
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--format=') })
          @options[:format] = @argv[idx].split('=', 2)[1].to_sym
          @argv.delete_at(idx)
        end

        # --file オプションの抽出
        if (idx = @argv.index('--file'))
          if (val = @argv[idx + 1])
            @options[:file] = val
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--file=') })
          @options[:file] = @argv[idx].split('=', 2)[1]
          @argv.delete_at(idx)
        end

        # ヘルプフラグの抽出
        if @argv.include?('--help') || @argv.include?('-h') || @argv.include?('help')
          @options[:help] = true
          @argv.delete('--help')
          @argv.delete('-h')
          @argv.delete('help')
        end

        # バージョンフラグの抽出
        return unless @argv.include?('--version') || @argv.include?('-v') || @argv.include?('version')

        @options[:version] = true
        @argv.delete('--version')
        @argv.delete('-v')
        @argv.delete('version')
      end

      def match_command?(prefix)
        prefix_words = prefix.split
        return false if @argv.length < prefix_words.length

        prefix_words.each_with_index do |word, idx|
          return false if @argv[idx] != word
        end

        @argv.shift(prefix_words.length)
        true
      end

      # 各種サブコマンドのスタブ実装

      def execute_init
        output_success('Project initialized.', { message: 'Project initialized' })
      end

      def execute_validate
        output_success('Validation successful.', { message: 'Validation successful' })
      end

      def execute_build
        output_success('Build successful.', { message: 'Build successful' })
      end

      def execute_plan
        output_success('Plan generated.', { message: 'Plan generated' })
      end

      def execute_deploy
        output_success('Deployment successful.', { message: 'Deployment successful' })
      end

      def execute_invoke_local
        name = @argv.first || 'default'
        output_success("Invoked local function: #{name}.", { message: "Invoked local function: #{name}" })
      end

      def execute_destroy
        output_success('Stack destroyed.', { message: 'Stack destroyed' })
      end

      def execute_efs_verify
        name = @argv.first || 'default'
        output_success("EFS verification successful for: #{name}.",
                       { message: "EFS verification successful for: #{name}" })
      end

      def execute_layer_inspect
        name = @argv.first || 'default'
        output_success("Inspected layer: #{name}.", { message: "Inspected layer: #{name}" })
      end

      def execute_schedule_preview
        name = @argv.first || 'default'
        output_success("Previewed schedule: #{name}.", { message: "Previewed schedule: #{name}" })
      end

      # ヘルプ・バージョン・エラー表示

      def print_version
        if @options[:format] == :json
          $stdout.puts JSON.generate({ version: Veltrunode::VERSION })
        else
          $stdout.puts Veltrunode::VERSION
        end
      end

      def print_help
        help_text = <<~HELP
          veltrunode - Ruby-first toolkit for AWS Lambda and EventBridge Scheduler

          Usage:
            veltrunode [options] <command> [arguments]

          Options:
            --help, -h               Show this help message
            --version, -v            Show version information
            --format <json|text>     Set output format (default: text)
            --file <path>            Set custom Veltrunodefile path (default: Veltrunodefile)

          Commands:
            init                       # Initialize a new Veltrunode project
            validate                   # Validate Veltrunodefile schema and settings
            build                      # Build functions and layers
            plan                       # Generate execution plan
            deploy                     # Deploy application stack
            invoke local NAME          # Execute Lambda function locally
            destroy                    # Destroy application stack
            efs verify NAME            # Verify EFS access and configuration
            layer inspect NAME         # Inspect Lambda Layer version
            schedule preview NAME      # Preview future run times for schedule
        HELP

        if @options[:format] == :json
          commands = [
            { name: 'init', description: 'Initialize a new Veltrunode project' },
            { name: 'validate', description: 'Validate Veltrunodefile schema and settings' },
            { name: 'build', description: 'Build functions and layers' },
            { name: 'plan', description: 'Generate execution plan' },
            { name: 'deploy', description: 'Deploy application stack' },
            { name: 'invoke local NAME', description: 'Execute Lambda function locally' },
            { name: 'destroy', description: 'Destroy application stack' },
            { name: 'efs verify NAME', description: 'Verify EFS access and configuration' },
            { name: 'layer inspect NAME', description: 'Inspect Lambda Layer version' },
            { name: 'schedule preview NAME', description: 'Preview future run times for schedule' }
          ]
          $stdout.puts JSON.generate({ commands: })
        else
          $stdout.puts help_text
        end
      end

      def handle_unknown_command(command)
        message = "Unknown command '#{command}'."
        handle_error(message, EXIT_INVALID_INPUT)
      end

      def handle_error(message, exit_code)
        if @options[:format] == :json
          output = {
            status: 'error',
            error_code: exit_code,
            message:
          }
          # rubocop:disable Style/StderrPuts
          $stderr.puts JSON.generate(output)
        else
          $stderr.puts "Error: #{message}"
          # rubocop:enable Style/StderrPuts
        end
        exit_code
      end

      def output_success(text, json_data = {})
        if @options[:format] == :json
          output = { status: 'success' }.merge(json_data)
          $stdout.puts JSON.generate(output)
        else
          $stdout.puts text
        end
        EXIT_SUCCESS
      end
    end
  end
end
