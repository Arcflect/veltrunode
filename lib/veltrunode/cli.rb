# frozen_string_literal: true

require 'json'
require_relative 'build'
require_relative 'compiler'
require_relative 'generator'
require_relative 'runner'
require_relative 'aws'
require_relative 'deploy'
require_relative 'destroy'
require_relative 'cli/json_formatter'

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
          file: 'Veltrunodefile',
          aws: false,
          runtime: 'ruby',
          count: 10
        }
        @current_command = nil
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
        elsif match_command?('layer prune') || match_command?('layer cleanup')
          execute_layer_prune
        elsif match_command?('schedule preview')
          execute_schedule_preview
        else
          handle_unknown_command(@argv.join(' '))
        end
      rescue StandardError => e
        exit_code = e.respond_to?(:exit_code) ? e.exit_code : EXIT_INVALID_INPUT
        diags = e.respond_to?(:diagnostics) ? e.diagnostics : []
        handle_error(e.message, exit_code, diagnostics: diags)
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

        # --no-cache フラグの抽出
        if @argv.include?('--no-cache')
          @options[:no_cache] = true
          @argv.delete('--no-cache')
        end

        # --aws フラグの抽出
        if @argv.include?('--aws')
          @options[:aws] = true
          @argv.delete('--aws')
        end

        # --event オプションの抽出
        if (idx = @argv.index('--event'))
          if (val = @argv[idx + 1])
            @options[:event] = val
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--event=') })
          @options[:event] = @argv[idx].split('=', 2)[1]
          @argv.delete_at(idx)
        end

        # --runtime オプションの抽出
        if (idx = @argv.index('--runtime'))
          if (val = @argv[idx + 1])
            @options[:runtime] = val
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--runtime=') })
          @options[:runtime] = @argv[idx].split('=', 2)[1]
          @argv.delete_at(idx)
        end

        # --bucket オプションの抽出
        if (idx = @argv.index('--bucket'))
          if (val = @argv[idx + 1])
            @options[:bucket] = val
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--bucket=') })
          @options[:bucket] = @argv[idx].split('=', 2)[1]
          @argv.delete_at(idx)
        end

        # --count オプションの抽出
        if (idx = @argv.index('--count'))
          if (val = @argv[idx + 1])
            @options[:count] = val
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--count=') })
          @options[:count] = @argv[idx].split('=', 2)[1]
          @argv.delete_at(idx)
        end

        # --yes フラグの抽出
        if @argv.include?('--yes') || @argv.include?('-y')
          @options[:yes] = true
          @options[:confirm] = true
          @argv.delete('--yes')
          @argv.delete('-y')
        end

        # --confirm フラグの抽出
        if @argv.include?('--confirm')
          @options[:confirm] = true
          @argv.delete('--confirm')
        end

        # --dry-run フラグの抽出
        if @argv.include?('--dry-run')
          @options[:dry_run] = true
          @argv.delete('--dry-run')
        end

        # --retain オプションの抽出
        if (idx = @argv.index('--retain'))
          if (val = @argv[idx + 1])
            @options[:retain] = val.to_i
            @argv.delete_at(idx + 1)
          end
          @argv.delete_at(idx)
        elsif (idx = @argv.find_index { |arg| arg.start_with?('--retain=') })
          @options[:retain] = @argv[idx].split('=', 2)[1].to_i
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
        @current_command = prefix
        true
      end

      # 各種サブコマンドのスタブ実装

      def execute_init
        target_dir = @argv.first || '.'
        runtime = @options[:runtime] || 'ruby'
        result = Veltrunode::Generator.run(target_dir, runtime: runtime)

        if @options[:format] == :json
          output_json_success({
                                'message' => 'Project initialized successfully.',
                                'created_files' => result.created_files,
                                'skipped_files' => result.skipped_files,
                                'target_dir' => result.target_dir
                              })
        else
          $stdout.puts 'Project initialized successfully.'
          unless result.created_files.empty?
            $stdout.puts 'Created files:'
            result.created_files.each { |f| $stdout.puts "  - #{f}" }
          end
          unless result.skipped_files.empty?
            $stdout.puts 'Skipped files (already exists):'
            result.skipped_files.each { |f| $stdout.puts "  - #{f}" }
          end
        end

        EXIT_SUCCESS
      end

      def execute_validate
        application = load_application!
        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        diagnostics = Veltrunode::Validation::Engine.run(application, source_dir: source_dir)

        if @options[:aws]
          require_relative 'aws/inspectors'
          aws_diags = Veltrunode::AWS::Inspectors::ConnectionInspector.inspect(application)
          diagnostics.concat(aws_diags)
        end

        errors = diagnostics.select { |d| d.severity == :error }

        return handle_validation_error(diagnostics) unless errors.empty?

        if @options[:format] == :json
          output_json_success(
            {
              'errors_count' => 0,
              'warnings_count' => diagnostics.count { |d| d.severity == :warning }
            },
            diagnostics
          )
        else
          diagnostics.each do |diag|
            prefix = diag.severity == :error ? '[ERROR]' : '[WARN]'
            $stdout.puts "#{prefix} [#{diag.code}] #{diag.summary}"
          end
          $stdout.puts 'Validation successful.'
        end

        EXIT_SUCCESS
      end

      def execute_build
        application = load_application!
        no_cache = @options[:no_cache] || false
        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        begin
          result = Veltrunode::Build::Pipeline.execute(
            application,
            source_dir: source_dir,
            no_cache: no_cache
          )
        rescue Veltrunode::ValidationError => e
          return handle_validation_error(e.diagnostics)
        rescue StandardError => e
          return handle_error(e.message, EXIT_BUILD_FAILED)
        end

        bucket = @options[:bucket] || (application.respond_to?(:artifact_bucket) ? application.artifact_bucket : nil)
        if bucket && !bucket.to_s.strip.empty?
          begin
            uploader = AWS::S3Uploader.new(bucket: bucket, application: application)
            uploader.upload_and_update_template(result)
          rescue AWS::S3UploadError, StandardError => e
            return handle_error("S3 upload failed: #{e.message}", EXIT_BUILD_FAILED)
          end
        end

        output_build_success(result)
      end

      def handle_validation_error(diagnostics)
        errors = diagnostics.select { |d| d.severity == :error }
        is_policy_violation = errors.any? do |d|
          d.code == 'VLT-IAM-001' || (d.evidence.is_a?(Hash) && d.evidence['policy_violation'])
        end
        exit_code = is_policy_violation ? EXIT_POLICY_VIOLATION : EXIT_VALIDATION_FAILED

        if @options[:format] == :json
          output_json_error(
            "Validation failed with #{errors.size} error(s).",
            exit_code,
            diagnostics,
            data: {
              'errors_count' => errors.size,
              'warnings_count' => diagnostics.count { |d| d.severity == :warning }
            }
          )
        else
          diagnostics.each do |diag|
            prefix = diag.severity == :error ? '[ERROR]' : '[WARN]'
            $stdout.puts "#{prefix} [#{diag.code}] #{diag.summary}"
          end
          # rubocop:disable-next Style/StderrPuts
          $stderr.puts "Validation failed with #{errors.size} error(s)."
        end

        exit_code
      end

      def output_build_success(result)
        if @options[:format] == :json
          output_json_success(result.to_h)
        else
          $stdout.puts 'Build successful.'
          $stdout.puts 'Generated artifacts:'

          unless result.function_results.empty?
            $stdout.puts '  Functions:'
            result.function_results.each do |fn_res|
              $stdout.puts "    - #{fn_res.function_name}: #{fn_res.zip_path} " \
                           "(SHA-256: #{fn_res.sha256}, #{fn_res.bytesize} bytes)"
            end
          end

          unless result.layer_results.empty?
            $stdout.puts '  Layers:'
            result.layer_results.each do |layer_res|
              if layer_res.respond_to?(:reused?) && layer_res.reused?
                $stdout.puts "    - #{layer_res.layer_name}: [REUSED] #{layer_res.layer_version_arn} " \
                             "(Content-Hash: #{layer_res.content_hash})"
              else
                $stdout.puts "    - #{layer_res.layer_name}: #{layer_res.zip_path} " \
                             "(SHA-256: #{layer_res.sha256}, #{layer_res.bytesize} bytes)"
              end
            end
          end

          $stdout.puts "  Template:\n    - #{result.template_path}"
          $stdout.puts "  Manifest:\n    - #{result.manifest_path}"

          if result.respond_to?(:size_diagnostics) && result.size_diagnostics
            $stdout.puts ''
            $stdout.puts result.size_diagnostics.to_text
          end
        end

        EXIT_SUCCESS
      end

      def execute_plan
        application = load_application!
        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        diagnostics = Veltrunode::Validation::Engine.run(application, source_dir: source_dir)
        errors = diagnostics.select { |d| d.severity == :error }
        return handle_validation_error(diagnostics) unless errors.empty?

        no_cache = @options[:no_cache] || false
        begin
          build_result = Veltrunode::Build::Pipeline.execute(
            application,
            source_dir: source_dir,
            no_cache: no_cache
          )
        rescue Veltrunode::ValidationError => e
          return handle_validation_error(e.diagnostics)
        rescue StandardError => e
          return handle_error("Plan failed during build: #{e.message}", EXIT_PLAN_FAILED)
        end

        bucket = @options[:bucket] || (application.respond_to?(:artifact_bucket) ? application.artifact_bucket : nil)
        if bucket && !bucket.to_s.strip.empty?
          begin
            uploader = AWS::S3Uploader.new(bucket: bucket, application: application)
            uploader.upload_and_update_template(build_result)
          rescue AWS::S3UploadError, StandardError => e
            return handle_error("S3 upload failed: #{e.message}", EXIT_PLAN_FAILED)
          end
        end

        begin
          manager = AWS::ChangeSetManager.new(application: application)
          cs_result = manager.create_and_describe_change_set(build_result.template_path)
        rescue AWS::ChangeSetError, StandardError => e
          return handle_error("Plan failed: #{e.message}", EXIT_PLAN_FAILED)
        end

        manifest_data = Veltrunode::Compiler::Manifest.build_data(application: application)
        iam_caps = manifest_data['iam_capabilities'] || {}
        warning_notice = 'Plan preview cannot eliminate all execution risks.'

        if @options[:format] == :json
          output_json_success({
                                'message' => "Plan generated for application '#{application.name}'.",
                                'stack_name' => cs_result.stack_name,
                                'change_set_name' => cs_result.change_set_name,
                                'summary' => cs_result.summary.transform_keys(&:to_s),
                                'changes' => cs_result.changes.map(&:to_h),
                                'iam_capabilities' => iam_caps,
                                'functions_count' => application.functions.size,
                                'schedules_count' => application.schedules.size,
                                'warning' => warning_notice
                              })
        else
          $stdout.puts "Plan generated for application '#{application.name}' " \
                       "(Stack: #{cs_result.stack_name}, Change Set: #{cs_result.change_set_name})."
          $stdout.puts "[NOTE] #{warning_notice}"
          $stdout.puts ''
          summary = cs_result.summary
          $stdout.puts "Resource Changes (Add: #{summary[:add]}, Modify: #{summary[:modify]}, " \
                       "Replace: #{summary[:replace]}, Remove: #{summary[:remove]}):"

          if cs_result.changes.empty?
            $stdout.puts '  (No resource changes detected)'
          else
            action_tags = {
              add: '[ADD]',
              modify: '[MODIFY]',
              remove: '[REMOVE]',
              replace: '[REPLACE *** EMPHASIS ***]'
            }.freeze

            cs_result.changes.each do |change|
              tag = action_tags[change.display_action]
              phys_str = change.physical_resource_id ? " (#{change.physical_resource_id})" : ''
              repl_str = change.replace? ? " [Replacement: #{change.replacement || 'Yes'}]" : ''
              $stdout.puts "  #{tag} #{change.logical_resource_id} [#{change.resource_type}]#{phys_str}#{repl_str}"
            end
          end

          $stdout.puts ''
          unless iam_caps.empty?
            $stdout.puts 'IAM Capabilities Expansion:'
            iam_caps.each do |fn_name, stmts|
              $stdout.puts "  Function '#{fn_name}':"
              if stmts.empty?
                $stdout.puts '    (none)'
              else
                stmts.each do |stmt|
                  actions = Array(stmt['Action']).join(', ')
                  resources = Array(stmt['Resource']).join(', ')
                  $stdout.puts "    - Effect: #{stmt['Effect']}, Action: [#{actions}], Resource: [#{resources}]"
                end
              end
            end
          end
        end

        EXIT_SUCCESS
      end

      def execute_deploy
        application = load_application!
        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        on_plan = lambda do |cs_result|
          next if @options[:format] == :json

          $stdout.puts "Plan generated for application '#{application.name}' " \
                       "(Stack: #{cs_result.stack_name}, Change Set: #{cs_result.change_set_name})."
          summary = cs_result.summary
          $stdout.puts "Resource Changes (Add: #{summary[:add]}, Modify: #{summary[:modify]}, " \
                       "Replace: #{summary[:replace]}, Remove: #{summary[:remove]}):"

          action_tags = {
            add: '[ADD]',
            modify: '[MODIFY]',
            remove: '[REMOVE]',
            replace: '[REPLACE *** EMPHASIS ***]'
          }.freeze

          cs_result.changes.each do |change|
            tag = action_tags[change.display_action]
            phys_str = change.physical_resource_id ? " (#{change.physical_resource_id})" : ''
            repl_str = change.replace? ? " [Replacement: #{change.replacement || 'Yes'}]" : ''
            $stdout.puts "  #{tag} #{change.logical_resource_id} [#{change.resource_type}]#{phys_str}#{repl_str}"
          end
        end

        on_progress = lambda do |event|
          next if @options[:format] == :json

          reason = event.resource_status_reason ? " (#{event.resource_status_reason})" : ''
          $stdout.puts "[PROGRESS] #{event.logical_resource_id} [#{event.resource_type}] " \
                       "#{event.resource_status}#{reason}"
        end

        result = Veltrunode::Deploy::Pipeline.execute(
          application,
          source_dir: source_dir,
          options: @options,
          on_plan: on_plan,
          on_progress: on_progress
        )

        handle_deploy_result(result)
      end

      def handle_deploy_result(result)
        if result.success?
          warnings = result.diagnostics.select { |d| d.severity == :warning }
          if @options[:format] == :json
            data = {
              'message' => result.message,
              'stack_name' => result.stack_name,
              'change_set_name' => result.change_set_name,
              'summary' => result.summary,
              'events' => result.events.map(&:to_h)
            }
            data['warnings_count'] = warnings.size unless warnings.empty?
            output_json_success(data, warnings)
          else
            output_deploy_diagnostics(result.diagnostics)
            $stdout.puts result.message
          end
          EXIT_SUCCESS
        else
          errors = result.diagnostics.select { |d| d.severity == :error }
          if @options[:format] == :json
            output_json_error(
              result.message,
              result.exit_code,
              result.diagnostics,
              data: {
                'errors_count' => errors.size,
                'warnings_count' => result.diagnostics.count { |d| d.severity == :warning }
              }
            )
          else
            result.diagnostics.each do |diag|
              prefix = diag.severity == :error ? '[ERROR]' : '[WARN]'
              $stdout.puts "#{prefix} [#{diag.code}] #{diag.summary}"
              if diag.suggested_action && !diag.suggested_action.empty?
                $stdout.puts "  Suggested action: #{diag.suggested_action}"
              end
            end
            # rubocop:disable-next Style/StderrPuts
            $stderr.puts result.message
          end
          result.exit_code
        end
      end

      def output_deploy_diagnostics(diagnostics)
        return if @options[:format] == :json

        diagnostics.select { |d| d.severity == :warning }.each do |diag|
          $stdout.puts "[WARN] [#{diag.code}] #{diag.summary}"
        end
      end

      def execute_invoke_local
        name = @argv.first
        if name.nil? || name.strip.empty?
          return handle_error('Function name is required for invoke local.', EXIT_INVALID_INPUT)
        end

        application = load_application!
        function = application.functions[name]
        unless function
          return handle_error("Function '#{name}' not found in application '#{application.name}'.",
                              EXIT_INVALID_INPUT)
        end

        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        event_data = load_event_data(source_dir)
        return event_data if event_data.is_a?(Integer)

        begin
          result = Veltrunode::Runner.run(
            function,
            event_data,
            application: application,
            source_dir: source_dir
          )
        rescue Veltrunode::Runner::TimeoutError, StandardError => e
          return handle_error(e.message, EXIT_INVALID_INPUT)
        end

        output_invoke_local_success(result)
      end

      def load_event_data(source_dir = Dir.pwd)
        event_file = @options[:event]
        return {} if event_file.nil? || event_file.strip.empty?

        resolved_file = File.expand_path(event_file, source_dir)
        return handle_error("Event file not found: #{event_file}", EXIT_INVALID_INPUT) unless File.exist?(resolved_file)

        content = File.read(resolved_file)
        begin
          JSON.parse(content)
        rescue JSON::ParserError => e
          handle_error("Invalid JSON in event file '#{event_file}': #{e.message}", EXIT_INVALID_INPUT)
        end
      end

      def output_invoke_local_success(result)
        if @options[:format] == :json
          output_json_success(result.to_h)
        else
          result.warnings.each do |warning|
            $stdout.puts "[WARN] #{warning}"
          end
          if result.result.is_a?(Hash) || result.result.is_a?(Array)
            $stdout.puts JSON.pretty_generate(result.result)
          else
            $stdout.puts result.result.to_s
          end
        end

        EXIT_SUCCESS
      end

      def execute_destroy
        application = load_application!

        on_preview = lambda do |stack_name, resources|
          next if @options[:format] == :json

          $stdout.puts "Destroy plan for stack '#{stack_name}':"
          $stdout.puts "  #{resources.size} resource(s) will be deleted:"
          resources.each do |r|
            phys_str = r.physical_resource_id ? " (#{r.physical_resource_id})" : ''
            $stdout.puts "  [DELETE] #{r.logical_resource_id} [#{r.resource_type}]#{phys_str}"
          end
        end

        on_progress = lambda do |event|
          next if @options[:format] == :json

          reason = event.resource_status_reason ? " (#{event.resource_status_reason})" : ''
          $stdout.puts "[PROGRESS] #{event.logical_resource_id} [#{event.resource_type}] " \
                       "#{event.resource_status}#{reason}"
        end

        prompter = build_destroy_prompter(application)

        result = Veltrunode::Destroy::Pipeline.execute(
          application,
          options: @options,
          on_preview: on_preview,
          on_progress: on_progress,
          prompter: prompter
        )

        handle_destroy_result(result)
      end

      def build_destroy_prompter(application)
        pipeline_class = Veltrunode::Destroy::Pipeline
        is_protected = pipeline_class.new(application).protected_stage?

        lambda do |stage, stack_name|
          if is_protected
            # 保護ステージ: スタック名の手入力を要求
            return false unless $stdin.respond_to?(:tty?) && $stdin.tty?

            $stdout.puts "This is a protected stage ('#{stage}'). This action is irreversible."
            $stdout.print "Type the stack name '#{stack_name}' to confirm deletion: "
            $stdout.flush
            input = $stdin.gets&.strip
            input == stack_name
          else
            # 非保護ステージ: --yes でスキップ、または y/N プロンプト
            return true if @options[:yes]
            return false unless $stdin.respond_to?(:tty?) && $stdin.tty?

            $stdout.print "Are you sure you want to delete stack '#{stack_name}'? [y/N]: "
            $stdout.flush
            answer = $stdin.gets&.strip&.downcase
            %w[y yes].include?(answer)
          end
        rescue StandardError
          false
        end
      end

      def handle_destroy_result(result)
        if result.success?
          if @options[:format] == :json
            output_json_success({
                                  'message' => result.message,
                                  'stack_name' => result.stack_name,
                                  'stack_not_found' => result.stack_not_found?,
                                  'resources' => result.resources.map(&:to_h),
                                  'events' => result.events.map(&:to_h)
                                })
          else
            $stdout.puts result.message
          end
          EXIT_SUCCESS
        else
          if @options[:format] == :json
            output_json_error(result.message, result.exit_code)
          else
            # rubocop:disable-next Style/StderrPuts
            $stderr.puts result.message
          end
          result.exit_code
        end
      end

      def execute_efs_verify
        @current_command = 'efs verify'
        app = load_application!
        name = @argv.first

        report = Veltrunode::AWS::Inspectors::EfsInspector.inspect(app, target_name: name)

        if @options[:format] == :json
          status_str = report.success? ? 'success' : 'error'
          data = report.to_h
          diags = report.diagnostics
          output_json(command: 'efs verify', status: status_str, diagnostics: diags, data: data)
        else
          print_efs_verify_text_report(report)
        end

        report.success? ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
      end

      def print_efs_verify_text_report(report)
        $stdout.puts '=' * 80
        $stdout.puts '  Veltrunode EFS Verification Report'
        $stdout.puts '=' * 80
        $stdout.puts "Target:              #{report.target_name}"
        $stdout.puts "Function:            #{report.function_name || '(none)'}"
        $stdout.puts "Access Point ID:     #{report.access_point_id || '(none)'}"
        $stdout.puts "File System ID:      #{report.file_system_id || '(none)'}"
        $stdout.puts "Overall Confidence:  #{report.overall_confidence}"
        $stdout.puts "\nChecks:"

        report.checks.each do |check|
          tag = case check.status
                when :passed then '[PASSED]'
                when :warning then '[WARNING]'
                when :failed then '[FAILED]'
                else '[SKIPPED]'
                end
          $stdout.puts "  #{tag.ljust(9)} #{format_check_name(check.name)} (confidence: #{check.confidence})"
          $stdout.puts "            - #{check.summary}"

          next unless check.diagnostic

          diag = check.diagnostic
          $stdout.puts "            - #{diag.code}: #{diag.summary}"
          $stdout.puts "              Suggested action: #{diag.suggested_action}"
        end

        unattached_diags = report.diagnostics - report.checks.map(&:diagnostic).compact
        unless unattached_diags.empty?
          $stdout.puts "\nDiagnostics:"
          unattached_diags.each do |diag|
            prefix = diag.severity == :error ? '[ERROR]' : '[WARN]'
            $stdout.puts "  #{prefix} #{diag.code}: #{diag.summary}"
            $stdout.puts "         Suggested action: #{diag.suggested_action}"
          end
        end

        $stdout.puts "\nDiagnostic Limitations:"
        report.limitations.each do |lim|
          $stdout.puts "  - #{lim}"
        end

        $stdout.puts "\n#{'-' * 80}"
        errors_count = report.diagnostics.count { |d| d.severity == :error }
        warnings_count = report.diagnostics.count { |d| d.severity == :warning }

        if report.success?
          status_msg = warnings_count.positive? ? "SUCCESS (#{warnings_count} warnings)" : 'SUCCESS (All checks passed)'
          $stdout.puts "Status: #{status_msg}"
        else
          $stdout.puts "Status: FAILED (#{errors_count} errors, #{warnings_count} warnings)"
        end
        $stdout.puts '=' * 80
      end

      def format_check_name(name)
        case name.to_s
        when 'access_point_status' then 'Access Point Status'
        when 'file_system_status' then 'File System Status'
        when 'vpc_consistency' then 'VPC Configuration Consistency'
        when 'mount_target_reachability' then 'Mount Target AZ Reachability'
        when 'security_group_egress' then 'Lambda Security Group Outbound (TCP 2049 Egress)'
        when 'security_group_ingress' then 'EFS Security Group Inbound (TCP 2049 Ingress)'
        when 'subnets_and_routes' then 'Subnet State & Route Table Verification'
        when 'posix_and_root_directory' then 'Access Point Root Directory & POSIX Identity'
        when 'lambda_iam_permissions' then 'Lambda Execution Role EFS IAM Permissions'
        when 'encryption_at_rest' then 'EFS Encryption at Rest'
        when 'backup_policy' then 'EFS Automatic Backup Policy'
        else
          name.to_s.split('_').map(&:capitalize).join(' ')
        end
      end

      def execute_layer_inspect
        @current_command = 'layer inspect'
        name = @argv.first
        if name.nil? || name.strip.empty?
          return handle_error('Layer name is required for layer inspect.', EXIT_INVALID_INPUT)
        end

        application = load_application!
        layer = application.layers.find { |l| l.name == name }
        unless layer
          return handle_error("Layer '#{name}' not found in application '#{application.name}'.",
                              EXIT_INVALID_INPUT)
        end

        source_dir = @options[:file] ? File.dirname(File.expand_path(@options[:file])) : Dir.pwd
        source_dir = Dir.pwd if source_dir.empty? || source_dir == '.'

        require_relative 'aws/inspectors'

        begin
          report = Veltrunode::AWS::Inspectors::LayerInspector.inspect(
            application,
            layer_name: name,
            source_dir: source_dir
          )
        rescue StandardError => e
          return handle_error(e.message, EXIT_INVALID_INPUT)
        end

        if @options[:format] == :json
          output_json(
            command: 'layer inspect',
            status: 'success',
            diagnostics: report.diagnostics,
            data: report.to_h
          )
        else
          print_layer_inspect_text(report)
        end

        EXIT_SUCCESS
      end

      def print_layer_inspect_text(report)
        $stdout.puts '=' * 80
        $stdout.puts '  Veltrunode Layer Inspection Report'
        $stdout.puts '=' * 80
        $stdout.puts "Layer Name:           #{report.layer_name}"
        $stdout.puts "Description:          #{report.description || '(none)'}"
        $stdout.puts "Content Hash:         #{report.content_hash}"
        $stdout.puts "Artifact SHA256:      #{report.sha256}"
        $stdout.puts "Compatible Runtimes:  #{report.compatible_runtimes.join(', ')}"
        $stdout.puts "Architectures:        #{report.architectures.join(', ')}"
        $stdout.puts "\nPackage Size:"
        $stdout.puts "  Compressed:         #{format_bytes(report.compressed_size)}"
        $stdout.puts "  Uncompressed:       #{format_bytes(report.uncompressed_size)}"
        $stdout.puts "  Total Entries:      #{report.total_entries}"
        $stdout.puts "\nReuse Status:"
        $stdout.puts "  Reusable:           #{report.reusable? ? 'Yes' : 'No'}"
        if report.matched_version
          $stdout.puts "  Matched Version:    Version #{report.matched_version} (#{report.matched_arn})"
        end
        $stdout.puts "  Reason:             #{report.reuse_reason}"
        $stdout.puts "\nPublished Versions (AWS):"
        if report.published_versions.empty?
          $stdout.puts '  (No published versions found on AWS or AWS not connected)'
        else
          report.published_versions.each do |v|
            desc = v['description'].to_s.empty? ? '(no description)' : v['description']
            $stdout.puts "  - Version #{v['version']} (#{v['created_date']}): #{desc}"
          end
        end
        $stdout.puts "\nLargest Entries:"
        if report.largest_entries.empty?
          $stdout.puts '  (No entries)'
        else
          report.largest_entries.each_with_index do |entry, idx|
            pct = "#{entry['percentage']}%".rjust(6)
            size_str = format_bytes(entry['size']).ljust(22)
            $stdout.puts "  ##{idx + 1}  #{pct}  #{size_str}  #{entry['path']}"
          end
        end
        $stdout.puts "\nDuplicate Files Across Resources:"
        if report.duplicate_files.empty?
          $stdout.puts '  None detected.'
        else
          report.duplicate_files.each do |dup|
            sources = Array(dup['duplicated_in']).join(', ')
            $stdout.puts "  - #{dup['path']} (#{format_bytes(dup['size'])})"
            $stdout.puts "    Also in:        #{sources}"
            $stdout.puts "    Recommendation: #{dup['recommendation']}" if dup['recommendation']
          end
        end
        $stdout.puts '=' * 80
      end

      def execute_layer_prune
        @current_command = 'layer prune'
        name = @argv.first
        if name.nil? || name.strip.empty?
          return handle_error('Layer name is required for layer prune.', EXIT_INVALID_INPUT)
        end

        application = load_application!
        layer = application.layers.find { |l| l.name == name }
        unless layer
          return handle_error("Layer '#{name}' not found in application '#{application.name}'.",
                              EXIT_INVALID_INPUT)
        end

        require_relative 'aws/layer_cleaner'

        dry_run = @options[:dry_run] || false
        retain_limit = @options[:retain]
        confirm = @options[:confirm] || @options[:yes] || false

        begin
          report = Veltrunode::AWS::LayerCleaner.prune(
            application: application,
            layer_name: name,
            retain_limit: retain_limit,
            dry_run: dry_run,
            confirm: confirm
          )
        rescue Veltrunode::AWS::LayerCleaner::ConfirmationRequiredError, StandardError => e
          return handle_error(e.message, EXIT_INVALID_INPUT)
        end

        if @options[:format] == :json
          output_json(
            command: 'layer prune',
            status: 'success',
            diagnostics: [],
            data: report.to_h
          )
        else
          print_layer_prune_text(report)
        end

        EXIT_SUCCESS
      end

      def print_layer_prune_text(report)
        title = report.dry_run? ? 'Veltrunode Layer Prune Report [DRY-RUN]' : 'Veltrunode Layer Prune Report'
        $stdout.puts '=' * 80
        $stdout.puts "  #{title}"
        $stdout.puts '=' * 80
        $stdout.puts "Layer Name:           #{report.layer_name}"
        $stdout.puts "Retention Policy:     Retain latest #{report.retained_limit} version(s)"
        $stdout.puts "Stage:                #{report.stage || '(default)'}"
        $stdout.puts "\nSummary:"
        $stdout.puts "  Total Versions:       #{report.summary['total_versions']}"
        $stdout.puts "  Retained Versions:    #{report.summary['retained_count']}"
        $stdout.puts "  Protected References: #{report.summary['referenced_count']}"
        action_label = report.dry_run? ? 'To Prune (Candidates):' : 'Pruned Versions:      '
        $stdout.puts "  #{action_label} #{report.summary['pruned_count']}"

        if report.pruned_versions.any?
          header = report.dry_run? ? "\nPrune Candidates:" : "\nPruned Versions:"
          $stdout.puts header
          report.pruned_versions.each do |item|
            $stdout.puts "  - Version #{item['version']}: #{item['layer_version_arn']} (#{item['created_date']})"
          end
        end

        if report.retained_versions.any?
          $stdout.puts "\nRetained Versions:"
          report.retained_versions.each do |item|
            reason_str = if item['status'] == 'retained_as_latest'
                           'Latest'
                         else
                           "Referenced by #{Array(item['references']).join(', ')}"
                         end
            $stdout.puts "  - Version #{item['version']} [#{reason_str}]: #{item['layer_version_arn']}"
          end
        end

        if report.summary['total_versions'].zero?
          $stdout.puts "\nNo published versions found for layer '#{report.layer_name}'."
        end

        $stdout.puts '=' * 80
      end

      def format_bytes(bytes)
        b = bytes.to_i
        if b >= 1_048_576
          format('%<mb>.1f MB (%<bytes>d bytes)', mb: b / 1_048_576.0, bytes: b)
        elsif b >= 1_024
          format('%<kb>.1f KB (%<bytes>d bytes)', kb: b / 1_024.0, bytes: b)
        else
          "#{b} bytes"
        end
      end

      def execute_schedule_preview
        @current_command = 'schedule preview'
        name = @argv.first
        if name.nil? || name.strip.empty?
          return handle_error('Schedule name is required for schedule preview.', EXIT_INVALID_INPUT)
        end

        count_raw = @options[:count]
        count = count_raw.to_s.strip.empty? ? 10 : count_raw.to_i
        if count <= 0 || (count_raw && count_raw.to_s !~ /\A\d+\z/)
          return handle_error("Invalid count '#{count_raw}'. Count must be a positive integer.", EXIT_INVALID_INPUT)
        end

        application = load_application!
        schedule = application.schedules.find { |s| s.name == name }
        unless schedule
          return handle_error("Schedule '#{name}' not found in application '#{application.name}'.",
                              EXIT_INVALID_INPUT)
        end

        require_relative 'scheduler'

        begin
          result = Veltrunode::Scheduler.preview(schedule, count: count)
        rescue Veltrunode::Scheduler::ScheduleExpressionError => e
          return handle_error(e.message, EXIT_VALIDATION_FAILED)
        rescue StandardError => e
          return handle_error(e.message, EXIT_INVALID_INPUT)
        end

        if @options[:format] == :json
          output_json(
            command: 'schedule preview',
            status: 'success',
            diagnostics: [],
            data: result.to_h
          )
        else
          print_schedule_preview_text(result)
        end

        EXIT_SUCCESS
      end

      def print_schedule_preview_text(result)
        $stdout.puts '=' * 80
        $stdout.puts '  Veltrunode Schedule Preview'
        $stdout.puts '=' * 80
        $stdout.puts "Schedule:         #{result.schedule_name}"
        $stdout.puts "Target Function:  #{result.target_function || '(none)'}"
        $stdout.puts "Expression:       #{result.expression} (#{result.expression_type})"
        $stdout.puts "Timezone:         #{result.timezone}"
        $stdout.puts "Count:            #{result.count}"
        $stdout.puts "Base Time (UTC):  #{result.from_time.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
        $stdout.puts "\nUpcoming Occurrences:"

        result.occurrences.each do |occ|
          seq = "##{occ.sequence}".ljust(5)
          local = occ.local_display.ljust(34)
          utc = occ.utc_display
          line = "  #{seq} #{local} |  #{utc}"
          if occ.dst_transition
            trans = occ.dst_transition
            line += "  * [DST Transition] #{trans.from_abbr} -> #{trans.to_abbr}"
          end
          $stdout.puts line
          $stdout.puts "        Notice: #{occ.shift_notice}" if occ.shift_notice
        end

        $stdout.puts "\nDST Transitions:"
        if result.dst_transitions.empty?
          $stdout.puts '  None in this preview window.'
        else
          result.dst_transitions.each do |dt|
            $stdout.puts "  - ##{dt.sequence}: #{dt.description}"
          end
        end

        $stdout.puts "\n#{'-' * 80}"
        $stdout.puts "Note: #{result.disclaimer}"
        $stdout.puts '=' * 80
      end

      def load_application!
        file_path = @options[:file]
        file_path = nil if file_path.respond_to?(:empty?) && file_path.empty?
        # rubocop:disable-next Naming/MemoizedInstanceVariableName
        @loaded_application ||= file_path ? Veltrunode::SettingsLoader.load(file_path: file_path) : Veltrunode::SettingsLoader.load
      end

      # ヘルプ・バージョン・エラー表示

      def print_version
        if @options[:format] == :json
          output_json_success({ 'version' => Veltrunode::VERSION }, command: 'version')
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
            --no-cache               Disable packaging cache
            --aws                    Run AWS connection and account constraint validation
            --runtime <name>         Set function runtime (default: ruby)
            --event <path>           Path to JSON event file for invoke local
            --bucket <name>          S3 bucket for artifact upload
            --yes, -y                Skip confirmation prompt for protected stage deployments
            --confirm                Explicitly confirm production cleanup / destroy
            --dry-run                Perform trial run without changing AWS resources
            --retain <num>           Number of latest layer versions to keep

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
            layer prune NAME           # Prune old Lambda Layer versions
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
            { name: 'layer prune NAME', description: 'Prune old Lambda Layer versions' },
            { name: 'schedule preview NAME', description: 'Preview future run times for schedule' }
          ]
          output_json_success({ 'commands' => commands }, command: 'help')
        else
          $stdout.puts help_text
        end
      end

      def handle_unknown_command(command)
        @current_command = 'unknown'
        message = "Unknown command '#{command}'."
        handle_error(message, EXIT_INVALID_INPUT)
      end

      def handle_error(message, exit_code, diagnostics: [], data: {})
        if @options[:format] == :json
          output_json_error(message, exit_code, diagnostics, data: data)
        else
          # rubocop:disable-next Style/StderrPuts
          $stderr.puts "Error: #{message}"
        end
        exit_code
      end

      def output_success(text, json_data = {})
        if @options[:format] == :json
          output_json_success(json_data)
        else
          $stdout.puts text
        end
        EXIT_SUCCESS
      end

      def output_json(command: @current_command, status: 'success', diagnostics: [], data: {}, stream: $stdout)
        json_str = JsonFormatter.format(
          command: command || 'unknown',
          status: status,
          diagnostics: diagnostics,
          data: data
        )
        stream.puts json_str
      end

      def output_json_success(data = {}, diagnostics = [], command: @current_command)
        output_json(command: command, status: 'success', diagnostics: diagnostics, data: data, stream: $stdout)
      end

      def output_json_error(message, exit_code, diagnostics = [], data: {}, command: @current_command)
        merged_data = { 'error_code' => exit_code, 'message' => message }.merge(data)
        output_json(command: command, status: 'error', diagnostics: diagnostics, data: merged_data, stream: $stderr)
      end
    end
  end
end
