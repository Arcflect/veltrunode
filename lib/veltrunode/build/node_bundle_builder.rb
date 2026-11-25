# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'deterministic_archiver'
require_relative 'package_result'
require_relative 'cache'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class NodeBundleBuilder
      DEFAULT_OUTPUT_DIR = 'build/artifacts/functions'
      BUILD_SCHEMA_VERSION = '1.0'

      class << self
        def build(**)
          new(**).build
        end

        def package(**)
          new(**).build
        end
      end

      attr_reader :function, :source_dir, :output_dir, :bundler, :runner_executable, :command_runner, :archiver

      def initialize(
        function:,
        source_dir:,
        output_dir: DEFAULT_OUTPUT_DIR,
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
        @runner_executable = runner_executable
        @command_runner = command_runner
        @archiver = archiver
        @bundler = resolve_bundler
        @execute_build = execute_build_enabled?(execute_build)
        @no_cache = no_cache
        @cache_dir = cache_dir ? File.expand_path(cache_dir.to_s) : File.join(@source_dir, '.veltrunode', 'cache')
        @cache_config = cache_config
        @s3_client = s3_client
      end

      def build
        fn_name = extract_function_name
        entry_rel = resolve_entry_rel_path
        entry_abs = File.expand_path(entry_rel, @source_dir)
        validate_entry_file!(fn_name, entry_rel, entry_abs)

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

        outfile_rel = resolve_outfile_rel_path
        result = Dir.mktmpdir('veltrunode_node_bundle_') do |staging_dir|
          staged_outfile = File.join(staging_dir, outfile_rel)
          FileUtils.mkdir_p(File.dirname(staged_outfile))

          cli_cmd = build_cli_command(outfile_path: staged_outfile)
          execute_bundler!(cli_cmd, fn_name) if @execute_build
          ensure_bundled_artifacts!(entry_abs, staged_outfile, outfile_rel)

          archive_result = @archiver.archive(
            source_dir: staging_dir,
            output_path: zip_path
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

      def build_cli_command(outfile_path: nil)
        target_out = outfile_path || resolve_outfile_rel_path
        if @bundler == 'bun'
          build_bun_cli_args(target_out)
        else
          build_esbuild_cli_args(target_out)
        end
      end

      def calculate_content_hash
        fn_name = extract_function_name
        files = collect_relevant_files
        file_digests = files.sort.map do |rel_path|
          abs_path = File.join(@source_dir, rel_path)
          next "missing:#{rel_path}" unless File.file?(abs_path)

          "file:#{rel_path}:#{Digest::SHA256.file(abs_path).hexdigest}"
        end

        raw = [
          "schema_version:#{BUILD_SCHEMA_VERSION}",
          'builder:NodeBundleBuilder',
          "function_name:#{fn_name}",
          "bundler:#{@bundler}",
          "entry:#{resolve_entry_rel_path}",
          "outfile:#{resolve_outfile_rel_path}",
          "target:#{resolve_target}",
          "format:#{resolve_format}",
          "sourcemap:#{resolve_sourcemap}",
          "minify:#{minify?}",
          "tree_shaking:#{tree_shaking?}",
          "external:#{resolve_external.sort.join(',')}",
          "files:\n#{file_digests.join("\n")}"
        ].join("\n")

        Digest::SHA256.hexdigest(raw)
      end

      private

      def execute_build_enabled?(explicit_flag)
        return explicit_flag ? true : false unless explicit_flag.nil?

        !@command_runner.nil? || !@runner_executable.nil?
      end

      def validate_entry_file!(fn_name, entry_rel, entry_abs)
        return if !entry_rel.empty? && File.file?(entry_abs)

        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-ENTRY-NOT-FOUND',
          severity: :error,
          summary: "Entry file not found for Node.js/TypeScript function '#{fn_name}': '#{entry_rel}'.",
          suggested_action: "Ensure entry file '#{entry_rel}' exists in '#{@source_dir}'.",
          evidence: {
            'function' => fn_name,
            'entry' => entry_rel,
            'resolved_path' => entry_abs
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def build_esbuild_cli_args(outfile_path)
        cfg = bundle_config
        cmd = [resolve_esbuild_executable, resolve_entry_rel_path, '--bundle', '--platform=node']
        cmd << "--target=#{resolve_target}"
        cmd << "--format=#{resolve_format}"
        cmd << '--tree-shaking=true' if tree_shaking?
        cmd << '--minify' if minify?

        smap = resolve_sourcemap
        case smap
        when true, 'true'
          cmd << '--sourcemap'
        when 'inline', 'external', 'linked', 'both'
          cmd << "--sourcemap=#{smap}"
        end

        resolve_external.each do |ext_pkg|
          cmd << "--external:#{ext_pkg}"
        end

        tsconfig = cfg['tsconfig'] || cfg[:tsconfig]
        cmd << "--tsconfig=#{tsconfig}" if tsconfig && !tsconfig.to_s.strip.empty?

        banner = cfg['banner'] || cfg[:banner]
        cmd << "--banner:js=#{banner}" if banner && !banner.to_s.empty?

        define_map = cfg['define'] || cfg[:define]
        if define_map.is_a?(Hash)
          define_map.keys.sort.each do |k|
            cmd << "--define:#{k}=#{define_map[k]}"
          end
        end

        extra_flags = cfg['build_flags'] || cfg[:build_flags]
        cmd.concat(Array(extra_flags).map(&:to_s)) if extra_flags

        cmd << "--outfile=#{outfile_path}"
        cmd
      end

      def build_bun_cli_args(outfile_path)
        cfg = bundle_config
        cmd = [resolve_bun_executable, 'build', resolve_entry_rel_path, '--target=node']
        cmd << "--format=#{resolve_format}"
        cmd << '--minify' if minify?

        smap = resolve_sourcemap
        case smap
        when true, 'true', 'external', 'linked'
          cmd << '--sourcemap=external'
        when 'inline'
          cmd << '--sourcemap=inline'
        end

        resolve_external.each do |ext_pkg|
          cmd << '--external' << ext_pkg
        end

        extra_flags = cfg['build_flags'] || cfg[:build_flags]
        cmd.concat(Array(extra_flags).map(&:to_s)) if extra_flags

        cmd << "--outfile=#{outfile_path}"
        cmd
      end

      def execute_bundler!(cli_cmd, fn_name)
        stdout_str, stderr_str, status = if @command_runner
                                           @command_runner.call(cli_cmd, chdir: @source_dir)
                                         else
                                           Open3.capture3(*cli_cmd, chdir: @source_dir)
                                         end

        success = status.respond_to?(:success?) ? status.success? : status == true
        return if success

        exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-BUNDLE-001',
          severity: :error,
          summary: "Node.js/TypeScript bundle failed with #{@bundler} for function '#{fn_name}' " \
                   "(exit code #{exit_code}).",
          suggested_action: "Check TypeScript syntax and #{@bundler} options for entry '#{resolve_entry_rel_path}'.",
          evidence: {
            'function' => fn_name,
            'bundler' => @bundler,
            'command' => cli_cmd.join(' '),
            'stdout' => stdout_str.to_s,
            'stderr' => stderr_str.to_s,
            'exit_code' => exit_code
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def ensure_bundled_artifacts!(entry_abs, staged_outfile, outfile_rel)
        smap = resolve_sourcemap
        wants_external_map = [true, 'true', 'external', 'linked', 'both'].include?(smap)
        wants_inline_map = %w[inline both].include?(smap.to_s)
        map_path = "#{staged_outfile}.map"

        unless File.file?(staged_outfile)
          ts_source = File.read(entry_abs)
          js_code = transpile_typescript_fallback(ts_source)
          if smap == true || smap.to_s == 'linked'
            js_code = "#{js_code}\n//# sourceMappingURL=#{File.basename(outfile_rel)}.map\n"
          elsif wants_inline_map
            encoded_map = [generate_source_map_json(entry_abs, outfile_rel, ts_source)].pack('m0')
            js_code = "#{js_code}\n//# sourceMappingURL=data:application/json;base64,#{encoded_map}\n"
          end
          File.write(staged_outfile, js_code)
        end

        return unless wants_external_map && !File.file?(map_path)

        ts_source = File.file?(entry_abs) ? File.read(entry_abs) : ''
        File.write(map_path, generate_source_map_json(entry_abs, outfile_rel, ts_source))
      end

      def transpile_typescript_fallback(source)
        code = source.dup
        code.gsub!(/^\s*import\s+type\s+.*?;\s*$/m, '')
        code.gsub!(/:\s*(?:string|number|boolean|any|unknown|void|Record<[^>]+>|Promise<[^>]+>)\b/, '')
        if resolve_format == 'cjs'
          code.gsub!(/\bexport\s+const\s+(\w+)\s*=/, 'exports.\1 =')
          code.gsub!(/\bexport\s+async\s+function\s+(\w+)/, 'exports.\1 = async function \1')
          code.gsub!(/\bexport\s+function\s+(\w+)/, 'exports.\1 = function \1')
        end
        "\"use strict\";\n#{code.strip}\n"
      end

      def generate_source_map_json(_entry_abs, outfile_rel, source_content)
        JSON.generate(
          'version' => 3,
          'file' => File.basename(outfile_rel),
          'sources' => [resolve_entry_rel_path],
          'sourcesContent' => [source_content],
          'names' => [],
          'mappings' => 'AAAA'
        )
      end

      def resolve_esbuild_executable
        return @runner_executable if @runner_executable && !@runner_executable.to_s.strip.empty?

        local_bin = File.join(@source_dir, 'node_modules', '.bin', 'esbuild')
        return local_bin if File.executable?(local_bin)

        'esbuild'
      end

      def resolve_bun_executable
        return @runner_executable if @runner_executable && !@runner_executable.to_s.strip.empty?

        'bun'
      end

      def resolve_bundler
        if @function.respond_to?(:bundler) && @function.bundler
          @function.bundler.to_s
        else
          cfg = bundle_config
          (cfg['bundler'] || cfg[:bundler] || 'esbuild').to_s
        end
      end

      def resolve_entry_rel_path
        if @function.respond_to?(:entry) && @function.entry
          @function.entry.to_s
        else
          cfg = bundle_config
          (cfg['entry'] || cfg[:entry]).to_s
        end
      end

      def resolve_outfile_rel_path
        if @function.respond_to?(:bundle_outfile) && @function.bundle_outfile
          @function.bundle_outfile.to_s
        else
          cfg = bundle_config
          out = cfg['outfile'] || cfg[:outfile]
          return out.to_s if out && !out.to_s.strip.empty?

          ext = resolve_format == 'esm' ? '.mjs' : '.js'
          base = File.basename(resolve_entry_rel_path).sub(/\.(?:[cm]?ts|tsx|[cm]?js|jsx)\z/i, '')
          "#{base.empty? ? 'index' : base}#{ext}"
        end
      end

      def resolve_target
        if @function.respond_to?(:bundle_target) && @function.bundle_target
          @function.bundle_target.to_s
        else
          cfg = bundle_config
          (cfg['target'] || cfg[:target] || 'node20').to_s
        end
      end

      def resolve_format
        cfg = bundle_config
        (cfg['format'] || cfg[:format] || 'cjs').to_s
      end

      def resolve_sourcemap
        if @function.respond_to?(:sourcemap) && !@function.sourcemap.nil?
          @function.sourcemap
        else
          cfg = bundle_config
          cfg.key?('sourcemap') ? cfg['sourcemap'] : (cfg[:sourcemap] || false)
        end
      end

      def minify?
        cfg = bundle_config
        cfg['minify'] || cfg[:minify] ? true : false
      end

      def tree_shaking?
        cfg = bundle_config
        return cfg['tree_shaking'] ? true : false if cfg.key?('tree_shaking')
        return cfg[:tree_shaking] ? true : false if cfg.key?(:tree_shaking)

        true
      end

      def resolve_external
        cfg = bundle_config
        Array(cfg['external'] || cfg[:external]).map(&:to_s)
      end

      def collect_relevant_files
        return [] unless File.directory?(@source_dir)

        patterns = [
          resolve_entry_rel_path,
          'package.json',
          'package-lock.json',
          'bun.lockb',
          'tsconfig.json',
          '**/*.ts',
          '**/*.tsx',
          '**/*.mts',
          '**/*.cts',
          '**/*.js',
          '**/*.mjs',
          '**/*.cjs'
        ]
        patterns.flat_map { |pat| Dir.glob(pat, base: @source_dir) }.uniq.select do |rel|
          !rel.start_with?('node_modules/', 'build/', 'dist/', '.git/', '.veltrunode/') &&
            File.file?(File.join(@source_dir, rel))
        end
      end

      def bundle_config
        if @function.respond_to?(:node_bundle) && @function.node_bundle.is_a?(Hash)
          @function.node_bundle
        elsif @function.is_a?(Hash)
          @function[:node_bundle] || @function['node_bundle'] || @function[:bundle] || @function['bundle'] || {}
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
    end
  end
end
