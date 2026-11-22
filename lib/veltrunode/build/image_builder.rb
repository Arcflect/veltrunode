# frozen_string_literal: true

require 'digest'
require 'open3'
require_relative 'container_runner'
require_relative 'package_result'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class ImageBuilder
      PLATFORM_MAP = ContainerRunner::PLATFORM_MAP

      class << self
        def build(function:, source_dir:, runner_executable: nil, command_runner: nil, execute_build: true)
          new(
            function: function,
            source_dir: source_dir,
            runner_executable: runner_executable,
            command_runner: command_runner,
            execute_build: execute_build
          ).build
        end

        def package(function:, source_dir:, runner_executable: nil, command_runner: nil, execute_build: nil)
          should_exec = if execute_build.nil?
                          !runner_executable.nil? || !command_runner.nil?
                        else
                          execute_build
                        end
          new(
            function: function,
            source_dir: source_dir,
            runner_executable: runner_executable,
            command_runner: command_runner,
            execute_build: should_exec
          ).build
        end
      end

      attr_reader :function, :source_dir, :runner_executable, :command_runner, :execute_build

      def initialize(function:, source_dir:, runner_executable: nil, command_runner: nil, execute_build: true)
        @function = function
        @source_dir = File.expand_path(source_dir.to_s)
        @runner_executable = runner_executable
        @command_runner = command_runner
        @execute_build = execute_build ? true : false
      end

      def build
        fn_name = extract_function_name
        dockerfile_rel = extract_dockerfile

        return build_uri_only_result(fn_name) if dockerfile_rel.nil? || dockerfile_rel.to_s.strip.empty?

        dockerfile_path = File.expand_path(dockerfile_rel.to_s, @source_dir)
        validate_dockerfile!(fn_name, dockerfile_rel, dockerfile_path)

        content_hash = calculate_content_hash(dockerfile_path)
        tag = extract_tag || "sha256-#{content_hash[0, 12]}"
        repo = extract_repository || fn_name
        local_image_uri = "#{repo}:#{tag}"

        cli_cmd = build_cli_command(
          dockerfile_path: dockerfile_path,
          image_tag: local_image_uri
        )

        execute_docker_build!(cli_cmd, fn_name) if @execute_build

        PackageResult.new(
          function_name: fn_name,
          zip_path: '',
          content_hash: content_hash,
          sha256: content_hash,
          bytesize: File.size(dockerfile_path),
          entries: [dockerfile_rel.to_s],
          diagnostics: [],
          cached: false,
          package_type: 'Image',
          image_uri: local_image_uri,
          image_tag: tag,
          dockerfile_path: dockerfile_path,
          build_command: cli_cmd
        )
      end

      def build_cli_command(dockerfile_path: nil, image_tag: nil)
        df_rel = extract_dockerfile
        resolved_df = dockerfile_path || (df_rel ? File.expand_path(df_rel.to_s, @source_dir) : nil)
        fn_name = extract_function_name
        repo = extract_repository || fn_name
        tag = extract_tag || 'latest'
        resolved_tag = image_tag || "#{repo}:#{tag}"

        exe = resolve_executable
        arch = extract_architecture
        platform = PLATFORM_MAP[arch.to_s] || 'linux/amd64'
        context_rel = extract_context || '.'
        context_dir = File.expand_path(context_rel.to_s, @source_dir)

        cmd = [exe, 'build', '--platform', platform]
        cmd << '-f' << resolved_df if resolved_df
        cmd << '-t' << resolved_tag

        target = extract_target
        cmd << '--target' << target.to_s if target && !target.to_s.strip.empty?

        build_args = extract_build_args
        if build_args.is_a?(Hash)
          build_args.keys.sort.each do |k|
            cmd << '--build-arg' << "#{k}=#{build_args[k]}"
          end
        end

        cmd << context_dir
        cmd
      end

      def calculate_content_hash(dockerfile_path = nil)
        fn_name = extract_function_name
        df_rel = extract_dockerfile
        resolved_df = dockerfile_path || (df_rel ? File.expand_path(df_rel.to_s, @source_dir) : nil)
        df_content = resolved_df && File.file?(resolved_df) ? File.binread(resolved_df) : ''

        digest = Digest::SHA256.new
        digest.update("IMAGE_BUILD_V1\0")
        digest.update("FUNCTION:#{fn_name}\0")
        digest.update("ARCH:#{extract_architecture}\0")
        digest.update("TAG:#{extract_tag}\0")
        digest.update("REPO:#{extract_repository}\0")
        digest.update("TARGET:#{extract_target}\0")

        build_args = extract_build_args
        if build_args.is_a?(Hash)
          build_args.keys.sort.each do |k|
            digest.update("ARG:#{k}=#{build_args[k]}\0")
          end
        end

        digest.update("DOCKERFILE:#{df_rel}\0")
        digest.update(df_content)
        digest.hexdigest
      end

      private

      def build_uri_only_result(fn_name)
        uri = extract_uri
        tag = extract_tag
        content_hash = Digest::SHA256.hexdigest("IMAGE_URI_V1:#{fn_name}:#{uri}:#{tag}")

        PackageResult.new(
          function_name: fn_name,
          zip_path: '',
          content_hash: content_hash,
          sha256: content_hash,
          bytesize: 0,
          entries: [],
          diagnostics: [],
          cached: false,
          package_type: 'Image',
          image_uri: uri&.to_s,
          image_tag: tag
        )
      end

      def resolve_executable
        return @runner_executable if @runner_executable && !@runner_executable.to_s.strip.empty?
        return ContainerRunner.validate_runtime_available! if @execute_build && @command_runner.nil?

        ContainerRunner.detect_executable || 'docker'
      end

      def validate_dockerfile!(fn_name, dockerfile_rel, dockerfile_path)
        return if File.file?(dockerfile_path)

        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-DOCKERFILE-NOT-FOUND',
          severity: :error,
          summary: "Dockerfile not found for function '#{fn_name}': '#{dockerfile_rel}'.",
          suggested_action: "Ensure Dockerfile '#{dockerfile_rel}' exists in '#{@source_dir}'.",
          evidence: {
            'function' => fn_name,
            'dockerfile' => dockerfile_rel.to_s,
            'resolved_path' => dockerfile_path
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def execute_docker_build!(cli_cmd, fn_name)
        stdout_str, stderr_str, status = if @command_runner
                                           @command_runner.call(cli_cmd)
                                         else
                                           Open3.capture3(*cli_cmd)
                                         end

        success = status.respond_to?(:success?) ? status.success? : status == true
        return if success

        exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-IMAGE-001',
          severity: :error,
          summary: "Docker image build failed for function '#{fn_name}' (exit code #{exit_code}).",
          suggested_action: "Check Dockerfile syntax and build context for function '#{fn_name}'.",
          evidence: {
            'function' => fn_name,
            'command' => cli_cmd.join(' '),
            'stdout' => stdout_str.to_s,
            'stderr' => stderr_str.to_s,
            'exit_code' => exit_code
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def extract_function_name
        if @function.respond_to?(:logical_name)
          @function.logical_name.to_s
        elsif @function.is_a?(Hash)
          (@function[:logical_name] || @function['logical_name']).to_s
        else
          @function.to_s
        end
      end

      def extract_architecture
        if @function.respond_to?(:architecture) && @function.architecture
          @function.architecture.to_s
        else
          'x86_64'
        end
      end

      def extract_dockerfile
        if @function.respond_to?(:image_dockerfile)
          @function.image_dockerfile
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['dockerfile'] || @function.image[:dockerfile]
        end
      end

      def extract_uri
        if @function.respond_to?(:image_uri)
          @function.image_uri
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['uri'] || @function.image[:uri]
        end
      end

      def extract_tag
        if @function.respond_to?(:image_tag)
          @function.image_tag
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['tag'] || @function.image[:tag]
        end
      end

      def extract_context
        if @function.respond_to?(:image_context)
          @function.image_context
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['context'] || @function.image[:context]
        end
      end

      def extract_repository
        if @function.respond_to?(:image_repository)
          @function.image_repository
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['repository'] || @function.image[:repository]
        end
      end

      def extract_build_args
        if @function.respond_to?(:image_build_args)
          @function.image_build_args
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['build_args'] || @function.image[:build_args]
        end
      end

      def extract_target
        if @function.respond_to?(:image_target)
          @function.image_target
        elsif @function.respond_to?(:image) && @function.image.is_a?(Hash)
          @function.image['target'] || @function.image[:target]
        end
      end
    end
  end
end
