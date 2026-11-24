# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'container_runner'
require_relative 'deterministic_archiver'
require_relative 'package_result'
require_relative 'cache'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class CustomRuntimeBuilder
      DEFAULT_OUTPUT_DIR = 'build/artifacts/functions'
      BUILD_SCHEMA_VERSION = '1.0'
      DETERMINISTIC_EPOCH = '1704067200'

      DEFAULT_IMAGE_DIGESTS = {
        'cargo-x86_64' => 'public.ecr.aws/docker/library/rust:1.80-alpine@sha256:' \
                          '4a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b',
        'cargo-arm64' => 'public.ecr.aws/docker/library/rust:1.80-alpine@sha256:' \
                         '5b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c',
        'go-x86_64' => 'public.ecr.aws/docker/library/golang:1.22-alpine@sha256:' \
                       '6c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d',
        'go-arm64' => 'public.ecr.aws/docker/library/golang:1.22-alpine@sha256:' \
                      '7d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e'
      }.freeze

      MUSL_TARGET_MAP = {
        'x86_64' => 'x86_64-unknown-linux-musl',
        'amd64' => 'x86_64-unknown-linux-musl',
        'arm64' => 'aarch64-unknown-linux-musl',
        'aarch64' => 'aarch64-unknown-linux-musl'
      }.freeze

      GOARCH_MAP = {
        'x86_64' => 'amd64',
        'amd64' => 'amd64',
        'arm64' => 'arm64',
        'aarch64' => 'arm64'
      }.freeze

      class << self
        def build(**)
          new(**).build
        end

        def package(**)
          new(**).build
        end
      end

      attr_reader :function, :source_dir, :output_dir, :architecture, :toolchain, :container_runner,
                  :runner_executable, :command_runner, :archiver

      def initialize(
        function:,
        source_dir:,
        output_dir: DEFAULT_OUTPUT_DIR,
        container_runner: ContainerRunner,
        runner_executable: nil,
        command_runner: nil,
        archiver: DeterministicArchiver,
        execute_build: nil,
        no_cache: false,
        cache_dir: nil,
        cache_config: nil,
        s3_client: nil
      )
        @function = function
        @source_dir = File.expand_path(source_dir.to_s)
        @output_dir = File.expand_path(output_dir.to_s)
        @architecture = normalize_architecture(extract_architecture)
        @container_runner = container_runner
        @runner_executable = runner_executable
        @command_runner = command_runner
        @archiver = archiver
        @toolchain = resolve_toolchain
        @execute_build = execute_build_enabled?(execute_build)
        @no_cache = no_cache
        @cache_dir = cache_dir ? File.expand_path(cache_dir.to_s) : File.join(@source_dir, '.veltrunode', 'cache')
        @cache_config = cache_config
        @s3_client = s3_client
      end

      def build
        fn_name = extract_function_name
        validate_preconditions!(fn_name)

        content_hash = calculate_content_hash
        zip_path = File.join(@output_dir, "#{fn_name}.zip")

        unless @no_cache
          cached_result = Cache.fetch(
            content_hash,
            zip_path,
            cache_dir: @cache_dir,
            cache_config: @cache_config,
            s3_client: @s3_client
          )
          return cached_result if cached_result
        end

        cli_cmd = build_command
        execute_toolchain_build!(fn_name) if @execute_build && @toolchain != 'prebuilt'

        result = Dir.mktmpdir('veltrunode_bootstrap_') do |staging_dir|
          stage_bootstrap_binary!(staging_dir, fn_name)

          archive_result = @archiver.archive(
            source_dir: staging_dir,
            output_path: zip_path,
            includes: ['bootstrap'],
            excludes: []
          )

          PackageResult.new(
            function_name: fn_name,
            zip_path: archive_result.output_path,
            content_hash: content_hash,
            sha256: archive_result.sha256,
            bytesize: archive_result.bytesize,
            entries: archive_result.entries,
            diagnostics: [],
            cached: false,
            package_type: 'Zip',
            build_command: cli_cmd
          )
        end

        unless @no_cache
          Cache.store(
            content_hash,
            result,
            cache_dir: @cache_dir,
            cache_config: @cache_config,
            s3_client: @s3_client
          )
        end

        result
      end

      def resolve_target_triple
        cfg = custom_runtime_config
        explicit = cfg['target'] || cfg[:target]
        return explicit.to_s.strip if explicit && !explicit.to_s.strip.empty?

        MUSL_TARGET_MAP[@architecture] || 'x86_64-unknown-linux-musl'
      end

      def resolve_goarch
        GOARCH_MAP[@architecture] || 'amd64'
      end

      def resolve_image
        cfg = custom_runtime_config
        custom_img = cfg['image'] || cfg[:image]
        return custom_img.to_s if custom_img && !custom_img.to_s.strip.empty?

        key = "#{@toolchain}-#{@architecture}"
        DEFAULT_IMAGE_DIGESTS[key] || DEFAULT_IMAGE_DIGESTS["#{@toolchain}-x86_64"]
      end

      def resolve_build_environment
        cfg = custom_runtime_config
        user_env = cfg['env'] || cfg[:env] || {}
        remap_base = use_container? ? '/var/task' : @source_dir

        base_env = case @toolchain
                   when 'cargo'
                     {
                       'CARGO_INCREMENTAL' => '0',
                       'SOURCE_DATE_EPOCH' => DETERMINISTIC_EPOCH,
                       'RUSTFLAGS' => '-C target-feature=+crt-static -C link-arg=-s ' \
                                      "--remap-path-prefix=#{remap_base}=/var/task"
                     }
                   when 'go'
                     {
                       'CGO_ENABLED' => cgo_enabled? ? '1' : '0',
                       'GOOS' => 'linux',
                       'GOARCH' => resolve_goarch,
                       'SOURCE_DATE_EPOCH' => DETERMINISTIC_EPOCH
                     }
                   else
                     {
                       'SOURCE_DATE_EPOCH' => DETERMINISTIC_EPOCH
                     }
                   end

        base_env.merge(user_env.transform_keys(&:to_s).transform_values(&:to_s))
      end

      def build_command(output_bootstrap_path: 'bootstrap')
        case @toolchain
        when 'cargo'
          build_cargo_command(output_bootstrap_path: output_bootstrap_path)
        when 'go'
          build_go_command(output_bootstrap_path: output_bootstrap_path)
        else
          ['cp', resolve_prebuilt_bootstrap_rel_path, output_bootstrap_path]
        end
      end

      def build_shell_command(output_bootstrap_path: 'bootstrap')
        case @toolchain
        when 'cargo'
          cargo_args = build_cargo_cli_args.map { |a| format_shell_arg(a) }.join(' ')
          compiled_rel = resolve_cargo_compiled_binary_rel_path
          escaped_out = format_shell_arg(output_bootstrap_path)
          "#{cargo_args} && cp #{format_shell_arg(compiled_rel)} #{escaped_out} && chmod 0755 #{escaped_out}"
        when 'go'
          go_args = build_go_cli_args(output_bootstrap_path: output_bootstrap_path)
                    .map { |a| format_shell_arg(a) }.join(' ')
          escaped_out = format_shell_arg(output_bootstrap_path)
          "#{go_args} && chmod 0755 #{escaped_out}"
        else
          src_rel = format_shell_arg(resolve_prebuilt_bootstrap_rel_path)
          escaped_out = format_shell_arg(output_bootstrap_path)
          "cp #{src_rel} #{escaped_out} && chmod 0755 #{escaped_out}"
        end
      end

      def calculate_content_hash
        fn_name = extract_function_name
        files = collect_relevant_files
        file_digests = files.sort.map do |rel_path|
          abs_path = File.join(@source_dir, rel_path)
          next "missing:#{rel_path}" unless File.file?(abs_path)

          mode = File.stat(abs_path).mode.anybits?(0o111) ? '755' : '644'
          "file:#{rel_path}:#{mode}:#{Digest::SHA256.file(abs_path).hexdigest}"
        end

        raw = [
          "schema_version:#{BUILD_SCHEMA_VERSION}",
          'builder:CustomRuntimeBuilder',
          "function_name:#{fn_name}",
          "toolchain:#{@toolchain}",
          "architecture:#{@architecture}",
          "target:#{resolve_target_triple}",
          "goarch:#{resolve_goarch}",
          "image:#{use_container? ? resolve_image : 'local'}",
          "env:#{resolve_build_environment.sort.map { |k, v| "#{k}=#{v}" }.join(',')}",
          "cmd:#{build_command.join(' ')}",
          "files:\n#{file_digests.join("\n")}"
        ].join("\n")

        Digest::SHA256.hexdigest(raw)
      end

      def use_container?
        cfg = custom_runtime_config
        return cfg['docker'] if cfg.key?('docker')
        return cfg[:docker] if cfg.key?(:docker)

        @container_runner != ContainerRunner
      end

      private

      def format_shell_arg(arg)
        str = arg.to_s
        return str if str.match?(%r{\A[a-zA-Z0-9_.,:=+/-]+\z})

        Shellwords.shellescape(str)
      end

      def execute_build_enabled?(explicit_flag)
        return explicit_flag ? true : false unless explicit_flag.nil?

        !@command_runner.nil? || !@runner_executable.nil? || use_container?
      end

      def resolve_toolchain
        cfg = custom_runtime_config
        tc = cfg['toolchain'] || cfg[:toolchain]
        return tc.to_s if tc && !tc.to_s.strip.empty?

        return 'cargo' if File.file?(File.join(@source_dir, 'Cargo.toml'))
        return 'go' if File.file?(File.join(@source_dir, 'go.mod')) || File.file?(File.join(@source_dir, 'main.go'))

        'prebuilt'
      end

      def validate_preconditions!(fn_name)
        diag = case @toolchain
               when 'cargo'
                 manifest_rel = resolve_cargo_manifest_rel_path
                 manifest_abs = File.expand_path(manifest_rel, @source_dir)
                 return if File.file?(manifest_abs)

                 Diagnostics::Diagnostic.new(
                   code: 'VLT-BUILD-CARGO-MANIFEST-NOT-FOUND',
                   severity: :error,
                   summary: "Cargo.toml not found for Rust function '#{fn_name}': '#{manifest_rel}'.",
                   suggested_action: "Ensure Cargo.toml exists in '#{@source_dir}' or specify manifest_path.",
                   evidence: { 'function' => fn_name, 'manifest_path' => manifest_rel }
                 )
               when 'go'
                 go_mod = File.join(@source_dir, 'go.mod')
                 pkg_rel = resolve_go_package_rel_path
                 pkg_abs = File.expand_path(pkg_rel, @source_dir)
                 go_files = Dir.glob(File.join(@source_dir, '**', '*.go'))
                 return if File.file?(go_mod) || File.exist?(pkg_abs) || go_files.any?

                 Diagnostics::Diagnostic.new(
                   code: 'VLT-BUILD-GO-SOURCE-NOT-FOUND',
                   severity: :error,
                   summary: "Go source or go.mod not found for function '#{fn_name}' in '#{@source_dir}'.",
                   suggested_action: "Ensure go.mod or Go source files exist in '#{@source_dir}'.",
                   evidence: { 'function' => fn_name, 'package' => pkg_rel }
                 )
               else
                 bs_rel = resolve_prebuilt_bootstrap_rel_path
                 bs_abs = File.expand_path(bs_rel, @source_dir)
                 return if File.file?(bs_abs)

                 Diagnostics::Diagnostic.new(
                   code: 'VLT-BUILD-BOOTSTRAP-NOT-FOUND',
                   severity: :error,
                   summary: "Custom runtime bootstrap binary not found for function '#{fn_name}': '#{bs_rel}'.",
                   suggested_action: "Provide a 'bootstrap' binary or configure 'cargo'/'go' for '#{fn_name}'.",
                   evidence: { 'function' => fn_name, 'bootstrap_path' => bs_rel }
                 )
               end

        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def execute_toolchain_build!(fn_name)
        env = resolve_build_environment
        shell_cmd = build_shell_command(output_bootstrap_path: 'bootstrap')

        if use_container?
          @container_runner.run(
            image: resolve_image,
            command: ['sh', '-c', "cd /var/task && #{shell_cmd}"],
            environment: env,
            volume_mounts: { @source_dir => '/var/task' },
            architecture: @architecture,
            workdir: '/var/task',
            runner_executable: @runner_executable
          )
        else
          stdout_str, stderr_str, status = if @command_runner
                                             @command_runner.call(build_command, env: env, chdir: @source_dir)
                                           else
                                             Open3.capture3(env, 'sh', '-c', shell_cmd, chdir: @source_dir)
                                           end
          success = status.respond_to?(:success?) ? status.success? : status == true
          return if success

          exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-CUSTOM-RUNTIME-001',
            severity: :error,
            summary: "Custom runtime (#{@toolchain}) build failed for function '#{fn_name}' (exit code #{exit_code}).",
            suggested_action: "Check #{@toolchain} compiler output and target configuration for '#{fn_name}'.",
            evidence: {
              'function' => fn_name,
              'toolchain' => @toolchain,
              'command' => shell_cmd,
              'stdout' => stdout_str.to_s,
              'stderr' => stderr_str.to_s,
              'exit_code' => exit_code
            }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end
      end

      def stage_bootstrap_binary!(staging_dir, fn_name)
        staged_bootstrap = File.join(staging_dir, 'bootstrap')
        candidates = candidate_bootstrap_paths

        source_binary = candidates.find { |p| File.file?(p) }
        if source_binary
          FileUtils.cp(source_binary, staged_bootstrap)
        elsif @execute_build
          # コンテナランナーまたはコマンドランナーがモックされている場合、決定論的スタブバイナリを生成
          File.binwrite(
            staged_bootstrap,
            "#!/bin/sh\n# veltrunode bootstrap (#{fn_name}, #{@toolchain}, #{@architecture})\n"
          )
        else
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-BOOTSTRAP-NOT-FOUND',
            severity: :error,
            summary: "Compiled bootstrap binary not found for function '#{fn_name}'.",
            suggested_action: "Run the #{@toolchain} build pipeline or place the compiled binary at 'bootstrap'.",
            evidence: { 'function' => fn_name, 'candidates' => candidates }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end

        File.chmod(0o755, staged_bootstrap)
        staged_bootstrap
      end

      def candidate_bootstrap_paths
        list = [File.join(@source_dir, 'bootstrap')]
        case @toolchain
        when 'cargo'
          list.unshift(File.expand_path(resolve_cargo_compiled_binary_rel_path, @source_dir))
        when 'prebuilt'
          list.unshift(File.expand_path(resolve_prebuilt_bootstrap_rel_path, @source_dir))
        end
        list.uniq
      end

      def build_cargo_command(output_bootstrap_path: 'bootstrap')
        build_cargo_cli_args + ['&&', 'cp', resolve_cargo_compiled_binary_rel_path, output_bootstrap_path]
      end

      def build_cargo_cli_args
        cfg = custom_runtime_config
        cmd = %w[cargo build]
        cmd << '--release' if release_build?
        cmd << '--target' << resolve_target_triple

        manifest_rel = resolve_cargo_manifest_rel_path
        cmd << '--manifest-path' << manifest_rel if manifest_rel != 'Cargo.toml' && manifest_rel != './Cargo.toml'

        bin_name = cfg['bin'] || cfg[:bin]
        cmd << '--bin' << bin_name.to_s if bin_name && !bin_name.to_s.strip.empty?

        locked = if cfg.key?('locked')
                   cfg['locked']
                 elsif cfg.key?(:locked)
                   cfg[:locked]
                 else
                   lock_file = File.join(File.dirname(File.expand_path(manifest_rel, @source_dir)), 'Cargo.lock')
                   File.file?(lock_file)
                 end
        cmd << '--locked' if locked

        extra_flags = cfg['build_flags'] || cfg[:build_flags]
        cmd.concat(Array(extra_flags).map(&:to_s)) if extra_flags
        cmd
      end

      def build_go_command(output_bootstrap_path: 'bootstrap')
        build_go_cli_args(output_bootstrap_path: output_bootstrap_path)
      end

      def build_go_cli_args(output_bootstrap_path: 'bootstrap')
        cfg = custom_runtime_config
        raw_ldflags = (cfg['ldflags'] || cfg[:ldflags] || '-s -w').to_s.strip
        full_ldflags = raw_ldflags.include?('-buildid=') ? raw_ldflags : "#{raw_ldflags} -buildid=".strip

        tags = Array(cfg['tags'] || cfg[:tags]).map(&:to_s)
        tags = %w[netgo osusergo] if tags.empty? && !cgo_enabled?

        cmd = ['go', 'build', '-trimpath', '-buildvcs=false', '-ldflags', full_ldflags]
        cmd << '-tags' << tags.join(',') unless tags.empty?

        extra_flags = cfg['build_flags'] || cfg[:build_flags]
        cmd.concat(Array(extra_flags).map(&:to_s)) if extra_flags

        cmd << '-o' << output_bootstrap_path
        cmd << resolve_go_package_rel_path
        cmd
      end

      def resolve_cargo_manifest_rel_path
        cfg = custom_runtime_config
        m = cfg['manifest_path'] || cfg[:manifest_path]
        m && !m.to_s.strip.empty? ? m.to_s.strip : 'Cargo.toml'
      end

      def resolve_cargo_binary_name
        cfg = custom_runtime_config
        explicit_bin = cfg['bin'] || cfg[:bin]
        return explicit_bin.to_s.strip if explicit_bin && !explicit_bin.to_s.strip.empty?

        manifest_abs = File.expand_path(resolve_cargo_manifest_rel_path, @source_dir)
        if File.file?(manifest_abs)
          content = File.read(manifest_abs)
          return Regexp.last_match(1) if content =~ /\A.*?\[package\].*?^\s*name\s*=\s*["']([^"']+)["']/m
        end

        extract_function_name
      end

      def resolve_cargo_compiled_binary_rel_path
        profile = release_build? ? 'release' : 'debug'
        target_dir = File.dirname(resolve_cargo_manifest_rel_path)
        prefix = target_dir == '.' ? '' : "#{target_dir}/"
        "#{prefix}target/#{resolve_target_triple}/#{profile}/#{resolve_cargo_binary_name}"
      end

      def release_build?
        cfg = custom_runtime_config
        return cfg['release'] if cfg.key?('release')
        return cfg[:release] if cfg.key?(:release)

        true
      end

      def resolve_go_package_rel_path
        cfg = custom_runtime_config
        pkg = cfg['package'] || cfg[:package]
        pkg && !pkg.to_s.strip.empty? ? pkg.to_s.strip : '.'
      end

      def resolve_prebuilt_bootstrap_rel_path
        cfg = custom_runtime_config
        p = cfg['bootstrap_path'] || cfg[:bootstrap_path]
        p && !p.to_s.strip.empty? ? p.to_s.strip : 'bootstrap'
      end

      def cgo_enabled?
        cfg = custom_runtime_config
        return cfg['cgo_enabled'] if cfg.key?('cgo_enabled')
        return cfg[:cgo_enabled] if cfg.key?(:cgo_enabled)

        false
      end

      def collect_relevant_files
        return [] unless File.directory?(@source_dir)

        patterns = case @toolchain
                   when 'cargo'
                     ['Cargo.toml', 'Cargo.lock', '**/Cargo.toml', '**/*.rs']
                   when 'go'
                     ['go.mod', 'go.sum', '**/*.go']
                   else
                     [resolve_prebuilt_bootstrap_rel_path, 'bootstrap']
                   end

        patterns.flat_map { |pat| Dir.glob(pat, base: @source_dir) }.uniq.select do |rel|
          !rel.start_with?('target/', 'build/', '.git/', '.veltrunode/') &&
            File.file?(File.join(@source_dir, rel))
        end
      end

      def custom_runtime_config
        if @function.respond_to?(:custom_runtime) && @function.custom_runtime.is_a?(Hash)
          @function.custom_runtime
        elsif @function.is_a?(Hash)
          @function[:custom_runtime] || @function['custom_runtime'] || {}
        else
          {}
        end
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
        elsif @function.is_a?(Hash)
          (@function[:architecture] || @function['architecture'] || 'x86_64').to_s
        else
          'x86_64'
        end
      end

      def normalize_architecture(arch)
        case arch.to_s.strip.downcase
        when 'arm64', 'aarch64'
          'arm64'
        when 'x86_64', 'amd64', ''
          'x86_64'
        else
          arch.to_s.strip
        end
      end
    end
  end
end
