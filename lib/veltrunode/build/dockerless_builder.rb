# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'shellwords'
require_relative 'container_runner'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class DockerlessBuilder
      ROOTLESS_RUNTIMES = %w[podman nerdctl finch].freeze

      class << self
        def build(**)
          new(**).build
        end
      end

      attr_reader :source_dir, :output_dir, :runtime, :architecture, :prebuilt_path, :no_docker,
                  :layer, :requirements_path, :package_json_path, :command_runner, :container_runner

      def initialize(
        source_dir:,
        output_dir:,
        runtime: 'ruby3.3',
        architecture: 'x86_64',
        prebuilt_path: nil,
        no_docker: false,
        prefer_rootless: false,
        image: nil,
        layer: nil,
        requirements_path: nil,
        package_json_path: nil,
        container_runner: ContainerRunner,
        command_runner: nil,
        execute_build: nil,
        fallback_reason: nil
      )
        @source_dir = File.expand_path(source_dir.to_s)
        @output_dir = File.expand_path(output_dir.to_s)
        @runtime = runtime.to_s.freeze
        @architecture = architecture.to_s.freeze
        @layer = layer
        @prebuilt_path = resolve_prebuilt_path(prebuilt_path)
        @no_docker = no_docker ? true : false
        @prefer_rootless = prefer_rootless ? true : false
        @image = image
        @requirements_path = requirements_path
        @package_json_path = package_json_path
        @container_runner = container_runner
        @command_runner = command_runner
        @execute_build = resolve_execute_build?(execute_build, command_runner)
        @fallback_reason = fallback_reason
      end

      def build
        FileUtils.mkdir_p(@output_dir)
        diagnostics = []

        return execute_prebuilt_import!(diagnostics) if @prebuilt_path

        if !@no_docker && @prefer_rootless
          rootless_exe = @container_runner.detect_rootless_executable
          return execute_rootless_container_build!(rootless_exe, diagnostics) if rootless_exe
        end

        execute_host_packaging!(diagnostics)
      end

      def build_host_command
        if @runtime.start_with?('python')
          req = @requirements_path && !@requirements_path.to_s.empty? ? @requirements_path : 'requirements.txt'
          ['pip', 'install', '-r', req.to_s, '-t', @output_dir]
        elsif @runtime.start_with?('node')
          lock_exists = File.file?(File.join(@source_dir, 'package-lock.json'))
          lock_exists ? %w[npm ci --production] : %w[npm install --production]
        else
          cache_dir = File.join(@source_dir, 'vendor', 'cache')
          if File.directory?(cache_dir) && Dir.glob(File.join(cache_dir, '*.gem')).any?
            [
              'sh', '-c',
              "bundle config set --local path #{Shellwords.shellescape(@output_dir)} && " \
              'bundle config set --local cache_all true && bundle install --local'
            ]
          else
            [
              'sh', '-c',
              "bundle config set --local path #{Shellwords.shellescape(@output_dir)} && bundle install"
            ]
          end
        end
      end

      private

      def execute_prebuilt_import!(diagnostics)
        unless File.exist?(@prebuilt_path)
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-PREBUILT-NOT-FOUND',
            severity: :error,
            summary: "External prebuilt binary/package path not found: '#{@prebuilt_path}'.",
            suggested_action: "Ensure prebuilt artifacts exist at '#{@prebuilt_path}' before running dockerless build.",
            evidence: {
              'prebuilt_path' => @prebuilt_path,
              'runtime' => @runtime,
              'architecture' => @architecture
            }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end

        diagnostics << build_fallback_diagnostic(
          strategy: 'prebuilt',
          detail: "Importing external prebuilt binaries from '#{@prebuilt_path}'."
        )

        if File.directory?(@prebuilt_path)
          FileUtils.cp_r(File.join(@prebuilt_path, '.'), @output_dir)
        else
          FileUtils.cp(@prebuilt_path, File.join(@output_dir, File.basename(@prebuilt_path)))
        end

        digest = calculate_prebuilt_digest(@prebuilt_path)
        {
          strategy: :prebuilt,
          image: 'prebuilt:local',
          image_digest: "sha256:#{digest}",
          architecture: @architecture,
          output_dir: @output_dir,
          diagnostics: diagnostics
        }
      end

      def execute_rootless_container_build!(rootless_exe, diagnostics)
        diagnostics << build_fallback_diagnostic(
          strategy: "rootless:#{rootless_exe}",
          detail: "Docker daemon unavailable; using rootless container runtime '#{rootless_exe}'."
        )

        target_img = @image || 'public.ecr.aws/amazonlinux/amazonlinux:2023'
        cmd = if @runtime.start_with?('python')
                ['sh', '-c', 'cd /var/task && pip install -r requirements.txt -t vendor/python']
              elsif @runtime.start_with?('node')
                ['sh', '-c', 'cd /var/task && npm install --production']
              else
                ['sh', '-c', 'cd /var/task && bundle config set --local path vendor/bundle && bundle install']
              end

        res = @container_runner.run(
          image: target_img,
          command: cmd,
          volume_mounts: { @source_dir => '/var/task' },
          architecture: @architecture,
          workdir: '/var/task',
          runner_executable: rootless_exe
        )

        digest = Digest::SHA256.hexdigest("rootless:#{rootless_exe}:#{target_img}:#{@runtime}:#{@architecture}")
        {
          strategy: :rootless_container,
          executable: rootless_exe,
          image: target_img,
          image_digest: "sha256:#{digest}",
          architecture: @architecture,
          output_dir: @output_dir,
          result: res,
          diagnostics: diagnostics
        }
      end

      def execute_host_packaging!(diagnostics)
        host_cmd = build_host_command
        diagnostics << build_fallback_diagnostic(
          strategy: 'host',
          detail: "Building native extensions on host environment without Docker (#{host_cmd.join(' ')})."
        )

        stage_vendor_cache_gems! if @runtime.start_with?('ruby')

        if @execute_build
          stdout_str, stderr_str, status = if @command_runner
                                             @command_runner.call(host_cmd, chdir: @source_dir)
                                           else
                                             Open3.capture3(*host_cmd, chdir: @source_dir)
                                           end
          success = status.respond_to?(:success?) ? status.success? : status == true
          unless success
            exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-BUILD-HOST-001',
              severity: :error,
              summary: "Host dockerless build failed for runtime '#{@runtime}' (exit code #{exit_code}).",
              suggested_action: 'Verify host compiler toolchain or provide prebuilt binaries via prebuilt_path.',
              evidence: {
                'command' => host_cmd.join(' '),
                'stdout' => stdout_str.to_s,
                'stderr' => stderr_str.to_s,
                'exit_code' => exit_code
              }
            )
            raise ValidationError.new(diag.summary, diagnostics: [diag])
          end
        end

        digest = Digest::SHA256.hexdigest("host:#{RUBY_PLATFORM}:#{@runtime}:#{@architecture}:#{host_cmd.join(' ')}")
        {
          strategy: :host,
          image: "host:#{RUBY_PLATFORM}",
          image_digest: "sha256:#{digest}",
          architecture: @architecture,
          output_dir: @output_dir,
          command: host_cmd,
          diagnostics: diagnostics
        }
      end

      def stage_vendor_cache_gems!
        cache_dir = File.join(@source_dir, 'vendor', 'cache')
        return unless File.directory?(cache_dir)

        abi = case @runtime
              when 'ruby3.4' then '3.4.0'
              when 'ruby3.2' then '3.2.0'
              else '3.3.0'
              end
        cache_target = File.join(@output_dir, 'ruby', abi, 'cache')
        FileUtils.mkdir_p(cache_target)
        Dir.glob(File.join(cache_dir, '*.gem')).each do |gem_file|
          FileUtils.cp(gem_file, File.join(cache_target, File.basename(gem_file)))
        end
      end

      def resolve_execute_build?(execute_build, command_runner)
        return !command_runner.nil? if execute_build.nil?

        execute_build ? true : false
      end

      def build_fallback_diagnostic(strategy:, detail:)
        reason = if @no_docker
                   'Docker build explicitly disabled (--no-docker)'
                 elsif @fallback_reason
                   @fallback_reason
                 else
                   'Docker daemon is unavailable in current environment'
                 end

        Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-DOCKER-FALLBACK',
          severity: :warning,
          summary: "#{reason}. #{detail}",
          suggested_action: 'Ensure target architecture compatibility or supply prebuilt Linux binaries for Lambda.',
          evidence: {
            'strategy' => strategy.to_s,
            'runtime' => @runtime,
            'architecture' => @architecture,
            'no_docker' => @no_docker
          }
        )
      end

      def resolve_prebuilt_path(explicit)
        raw = explicit
        if raw.nil? && @layer.respond_to?(:prebuilt_path)
          raw = @layer.prebuilt_path
        elsif raw.nil? && @layer.respond_to?(:build_environment) && @layer.build_environment.is_a?(Hash)
          raw = @layer.build_environment['prebuilt_path'] || @layer.build_environment[:prebuilt_path]
        end

        return File.expand_path(raw.to_s.strip, @source_dir) if raw && !raw.to_s.strip.empty?

        default_prebuilt = File.join(@source_dir, 'vendor', 'prebuilt')
        File.directory?(default_prebuilt) ? default_prebuilt : nil
      end

      def calculate_prebuilt_digest(path)
        return Digest::SHA256.file(path).hexdigest if File.file?(path)

        files = Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort
        entries = files.map do |f|
          rel = f.delete_prefix("#{path}/")
          "#{rel}:#{Digest::SHA256.file(f).hexdigest}"
        end
        Digest::SHA256.hexdigest("prebuilt_v1:#{entries.join("\n")}")
      end
    end
  end
end
