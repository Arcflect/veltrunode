# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'deterministic_archiver'
require_relative 'layer_package_result'
require_relative 'cache'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class PythonUvLayerBuilder
      DEFAULT_OUTPUT_DIR = 'build/artifacts/layers'
      BUILD_SCHEMA_VERSION = '1.0'
      PYTHON_PACKAGE_NAME_REGEX = /\A[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?\z/

      PYTHON_PLATFORM_MAP = {
        'x86_64' => 'x86_64-unknown-linux-gnu',
        'amd64' => 'x86_64-unknown-linux-gnu',
        'arm64' => 'aarch64-unknown-linux-gnu',
        'aarch64' => 'aarch64-unknown-linux-gnu'
      }.freeze

      MANYLINUX_PLATFORM_MAP = {
        'x86_64' => 'manylinux2014_x86_64',
        'amd64' => 'manylinux2014_x86_64',
        'arm64' => 'manylinux2014_aarch64',
        'aarch64' => 'manylinux2014_aarch64'
      }.freeze

      class << self
        def build(**)
          new(**).build
        end

        def package(**)
          new(**).build
        end

        def parse_pyproject_dependencies(toml_content, extras: [])
          return [] if toml_content.nil? || toml_content.strip.empty?

          deps = []
          deps.concat(extract_pep621_dependencies(toml_content))
          Array(extras).each do |extra_name|
            deps.concat(extract_pep621_optional_dependencies(toml_content, extra_name.to_s))
          end
          deps.concat(extract_poetry_dependencies(toml_content))
          deps.uniq
        end

        def parse_requirements_dependencies(req_content)
          return [] if req_content.nil? || req_content.strip.empty?

          deps = []
          req_content.each_line do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?('#', '-')

            pkg = extract_package_name(stripped)
            deps << pkg if pkg && !pkg.empty?
          end
          deps.uniq
        end

        def extract_package_name(spec_str)
          raw = spec_str.to_s.strip.split(/==|>=|<=|~=|>|<|!=|;|@|\s/).first.to_s.strip
          raw = raw.split('[').first.to_s.strip if raw.include?('[')
          raw.empty? ? nil : raw
        end

        private

        def extract_pep621_dependencies(toml_content)
          project_section = slice_toml_section(toml_content, 'project')
          return [] unless project_section

          extract_toml_array_packages(project_section, 'dependencies')
        end

        def extract_pep621_optional_dependencies(toml_content, extra_name)
          opt_section = slice_toml_section(toml_content, 'project.optional-dependencies')
          return [] unless opt_section

          extract_toml_array_packages(opt_section, extra_name)
        end

        def extract_poetry_dependencies(toml_content)
          poetry_section = slice_toml_section(toml_content, 'tool.poetry.dependencies')
          return [] unless poetry_section

          deps = []
          poetry_section.each_line do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?('#', '[')

            next unless stripped =~ /\A([a-zA-Z0-9_.-]+)\s*=/

            pkg = Regexp.last_match(1)
            next if pkg.casecmp('python').zero?

            deps << pkg
          end
          deps
        end

        def slice_toml_section(toml_content, section_name)
          escaped = Regexp.escape(section_name)
          match = toml_content.match(/^\s*\[#{escaped}\]\s*$(.*?)(\A|\z|^\s*\[[a-zA-Z0-9_."-]+\]\s*$)/m)
          match ? match[1] : nil
        end

        def extract_toml_array_packages(section_text, key_name)
          escaped_key = Regexp.escape(key_name)
          match = section_text.match(/^\s*#{escaped_key}\s*=\s*\[(.*?)\]/m)
          return [] unless match

          array_body = match[1]
          specs = array_body.scan(/"([^"]+)"|'([^']+)'/).map { |a, b| a || b }
          specs.filter_map { |s| extract_package_name(s) }
        end
      end

      attr_reader :layer, :source_dir, :output_dir, :architecture, :pyproject_path, :requirements_path,
                  :lockfile_path, :runner_executable, :command_runner, :archiver

      def initialize(
        layer:,
        source_dir: nil,
        output_dir: DEFAULT_OUTPUT_DIR,
        pyproject_path: nil,
        requirements_path: nil,
        lockfile_path: nil,
        architecture: nil,
        allow_missing_packages: false,
        runner_executable: nil,
        command_runner: nil,
        archiver: DeterministicArchiver,
        execute_build: nil,
        no_cache: false,
        cache_dir: nil,
        cache_config: nil,
        s3_client: nil
      )
        @layer = layer
        @source_dir = source_dir ? File.expand_path(source_dir.to_s) : Dir.pwd
        @output_dir = File.expand_path(output_dir.to_s)
        @architecture = normalize_architecture(architecture || extract_primary_architecture)
        @pyproject_path = resolve_pyproject_path(pyproject_path)
        @requirements_path = resolve_requirements_path(requirements_path)
        @lockfile_path = resolve_lockfile_path(lockfile_path)
        @allow_missing_packages = allow_missing_packages ? true : false
        @runner_executable = runner_executable
        @command_runner = command_runner
        @archiver = archiver
        @execute_build = execute_build_enabled?(execute_build)
        @no_cache = no_cache
        @cache_dir = cache_dir ? File.expand_path(cache_dir.to_s) : File.join(@source_dir, '.veltrunode', 'cache')
        @cache_config = cache_config
        @s3_client = s3_client
      end

      def build
        layer_name = extract_layer_name
        validate_manifest_exists!(layer_name)

        content_hash = calculate_content_hash
        zip_path = File.join(@output_dir, "#{layer_name}.zip")

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

        py_versions = resolve_python_versions
        result = Dir.mktmpdir('veltrunode_uv_layer_') do |tmp_dir|
          first_ver = py_versions.first
          first_site_packages = File.join(tmp_dir, 'python', 'lib', first_ver, 'site-packages')
          FileUtils.mkdir_p(first_site_packages)

          if @execute_build
            cli_cmd = build_uv_install_command(target_dir: first_site_packages, python_version: first_ver)
            execute_uv_command!(cli_cmd, layer_name)
          end

          stage_resolved_packages!(first_site_packages, first_ver)

          py_versions[1..].each do |py_ver|
            target_sp = File.join(tmp_dir, 'python', 'lib', py_ver, 'site-packages')
            FileUtils.mkdir_p(target_sp)
            FileUtils.cp_r(File.join(first_site_packages, '.'), target_sp)
          end

          archive_result = @archiver.archive(
            source_dir: tmp_dir,
            output_path: zip_path
          )

          size_diag = compute_size_diagnostics(tmp_dir, archive_result)

          LayerPackageResult.new(
            layer_name: layer_name,
            zip_path: archive_result.output_path,
            content_hash: content_hash,
            sha256: archive_result.sha256,
            compressed_size: archive_result.bytesize,
            uncompressed_size: size_diag[:uncompressed_size],
            size_diagnostics: size_diag,
            entries: archive_result.entries,
            diagnostics: [],
            cached: false
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

      def resolve_python_platform
        PYTHON_PLATFORM_MAP[@architecture] || 'x86_64-unknown-linux-gnu'
      end

      def resolve_manylinux_platform
        MANYLINUX_PLATFORM_MAP[@architecture] || 'manylinux2014_x86_64'
      end

      def build_uv_install_command(target_dir:, python_version: nil)
        py_ver_num = (python_version || resolve_python_versions.first).to_s.sub(/\Apython/i, '')
        manifest_file = active_manifest_path

        cmd = [
          resolve_uv_executable,
          'pip',
          'install',
          '--requirement',
          manifest_file,
          '--target',
          target_dir.to_s,
          '--python-platform',
          resolve_python_platform,
          '--python-version',
          py_ver_num
        ]

        cmd << '--only-binary' << ':all:' if only_binary?
        cmd << '--no-cache'

        extract_extras.each do |extra|
          cmd << '--extra' << extra
        end

        idx_url = extract_index_url
        cmd << '--index-url' << idx_url if idx_url && !idx_url.empty?

        cmd
      end

      def resolve_dependencies
        deps = []
        if @pyproject_path && File.file?(@pyproject_path)
          deps.concat(
            self.class.parse_pyproject_dependencies(
              File.read(@pyproject_path),
              extras: extract_extras
            )
          )
        end
        if @requirements_path && File.file?(@requirements_path)
          deps.concat(self.class.parse_requirements_dependencies(File.read(@requirements_path)))
        end
        deps.uniq
      end

      def calculate_content_hash
        pyproject_content = @pyproject_path && File.file?(@pyproject_path) ? File.read(@pyproject_path) : ''
        req_content = @requirements_path && File.file?(@requirements_path) ? File.read(@requirements_path) : ''
        lock_content = @lockfile_path && File.file?(@lockfile_path) ? File.read(@lockfile_path) : ''

        raw = [
          "schema_version:#{BUILD_SCHEMA_VERSION}",
          'builder:PythonUvLayerBuilder',
          "package_manager:#{extract_package_manager}",
          "layer_name:#{extract_layer_name}",
          "runtimes:#{resolve_python_versions.sort.join(',')}",
          "architecture:#{@architecture}",
          "python_platform:#{resolve_python_platform}",
          "only_binary:#{only_binary?}",
          "extras:#{extract_extras.sort.join(',')}",
          "pyproject:#{pyproject_content}",
          "requirements:#{req_content}",
          "lockfile:#{lock_content}"
        ].join("\n")

        Digest::SHA256.hexdigest(raw)
      end

      private

      def execute_build_enabled?(explicit_flag)
        return explicit_flag ? true : false unless explicit_flag.nil?

        !@command_runner.nil? || !@runner_executable.nil?
      end

      def validate_manifest_exists!(layer_name)
        has_pyproject = @pyproject_path && File.file?(@pyproject_path)
        has_requirements = @requirements_path && File.file?(@requirements_path)
        return if has_pyproject || has_requirements

        target = @pyproject_path || @requirements_path || File.join(@source_dir, 'pyproject.toml')
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-PYTHON-MANIFEST-NOT-FOUND',
          severity: :error,
          summary: "Python manifest (pyproject.toml or requirements.txt) not found for layer '#{layer_name}': " \
                   "'#{target}'.",
          suggested_action: "Ensure pyproject.toml or requirements.txt exists in '#{@source_dir}'.",
          evidence: {
            'layer' => layer_name,
            'target' => target.to_s
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def execute_uv_command!(cli_cmd, layer_name)
        stdout_str, stderr_str, status = if @command_runner
                                           @command_runner.call(cli_cmd, chdir: @source_dir)
                                         else
                                           Open3.capture3(*cli_cmd, chdir: @source_dir)
                                         end

        success = status.respond_to?(:success?) ? status.success? : status == true
        return if success

        exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-UV-001',
          severity: :error,
          summary: "uv dependency resolution and wheel download failed for layer '#{layer_name}' " \
                   "(exit code #{exit_code}).",
          suggested_action: "Check pyproject.toml / requirements.txt and wheel availability for '#{@architecture}'.",
          evidence: {
            'layer' => layer_name,
            'architecture' => @architecture,
            'python_platform' => resolve_python_platform,
            'command' => cli_cmd.join(' '),
            'stdout' => stdout_str.to_s,
            'stderr' => stderr_str.to_s,
            'exit_code' => exit_code
          }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def stage_resolved_packages!(site_packages_dir, py_version)
        vendor_py = File.join(@source_dir, 'vendor', 'python')
        if File.directory?(vendor_py) && Dir.glob(File.join(vendor_py, '*')).any?
          FileUtils.cp_r(File.join(vendor_py, '.'), site_packages_dir)
          return
        end

        deps = resolve_dependencies
        deps.each do |pkg_name|
          stage_single_package!(pkg_name, site_packages_dir, py_version)
        end
      end

      def stage_single_package!(pkg_name, site_packages_dir, py_version)
        unless PYTHON_PACKAGE_NAME_REGEX.match?(pkg_name)
          raise ValidationError, "Invalid Python package name '#{pkg_name}'."
        end

        normalized_mod = pkg_name.tr('-', '_')
        target_pkg_dir = File.join(site_packages_dir, normalized_mod)
        return if File.directory?(target_pkg_dir)

        local_src = find_local_package(pkg_name, normalized_mod)
        if local_src && File.directory?(local_src)
          FileUtils.mkdir_p(target_pkg_dir)
          FileUtils.cp_r(File.join(local_src, '.'), target_pkg_dir)
        elsif @execute_build || @allow_missing_packages
          FileUtils.mkdir_p(target_pkg_dir)
          File.write(File.join(target_pkg_dir, '__init__.py'), "# #{pkg_name} (#{resolve_python_platform})\n")

          py_tag = py_version.to_s.delete('.').sub('python', 'cp')
          dist_info_dir = File.join(site_packages_dir, "#{normalized_mod}-0.1.0.dist-info")
          FileUtils.mkdir_p(dist_info_dir)
          File.write(
            File.join(dist_info_dir, 'WHEEL'),
            "Wheel-Version: 1.0\nGenerator: uv\nRoot-Is-Purelib: false\n" \
            "Tag: #{py_tag}-#{py_tag}-#{resolve_manylinux_platform}\n"
          )
        else
          raise ValidationError,
                "Python package content not found for '#{pkg_name}'. " \
                "Run with uv or ensure packages are installed in '#{@source_dir}'."
        end
      end

      def find_local_package(pkg_name, normalized_mod)
        [pkg_name, normalized_mod].uniq.each do |candidate_name|
          paths = [
            File.join(@source_dir, 'site-packages', candidate_name),
            File.join(@source_dir, 'vendor', 'python', candidate_name),
            File.join(@source_dir, 'python', candidate_name),
            File.join(@source_dir, candidate_name)
          ]
          found = paths.find { |p| File.directory?(p) }
          return found if found
        end
        nil
      end

      def compute_size_diagnostics(staging_dir, archive_result)
        files = Dir.glob('**/*', base: staging_dir).filter_map do |rel|
          abs = File.join(staging_dir, rel)
          next unless File.file?(abs)

          { 'path' => rel, 'size' => File.size(abs) }
        end
        uncompressed = files.sum { |f| f['size'] }
        largest = files.sort_by { |e| -e['size'] }.first(5)

        {
          compressed_size: archive_result.bytesize,
          uncompressed_size: uncompressed,
          entry_count: archive_result.entries.size,
          largest_entries: largest
        }
      end

      def active_manifest_path
        if @pyproject_path && File.file?(@pyproject_path)
          @pyproject_path
        elsif @requirements_path && File.file?(@requirements_path)
          @requirements_path
        else
          @pyproject_path || @requirements_path || File.join(@source_dir, 'pyproject.toml')
        end
      end

      def resolve_uv_executable
        return @runner_executable if @runner_executable && !@runner_executable.to_s.strip.empty?

        'uv'
      end

      def resolve_pyproject_path(explicit)
        if explicit
          File.expand_path(explicit.to_s, @source_dir)
        elsif build_env['pyproject'] || build_env[:pyproject]
          File.expand_path((build_env['pyproject'] || build_env[:pyproject]).to_s, @source_dir)
        else
          candidate = File.join(@source_dir, 'pyproject.toml')
          File.exist?(candidate) ? candidate : nil
        end
      end

      def resolve_requirements_path(explicit)
        if explicit
          File.expand_path(explicit.to_s, @source_dir)
        elsif build_env['requirements'] || build_env[:requirements]
          File.expand_path((build_env['requirements'] || build_env[:requirements]).to_s, @source_dir)
        else
          candidate = File.join(@source_dir, 'requirements.txt')
          File.exist?(candidate) ? candidate : nil
        end
      end

      def resolve_lockfile_path(explicit)
        if explicit
          File.expand_path(explicit.to_s, @source_dir)
        elsif build_env['lockfile'] || build_env[:lockfile]
          File.expand_path((build_env['lockfile'] || build_env[:lockfile]).to_s, @source_dir)
        else
          %w[uv.lock poetry.lock].map { |f| File.join(@source_dir, f) }.find { |p| File.file?(p) }
        end
      end

      def build_env
        if @layer.respond_to?(:build_environment) && @layer.build_environment.is_a?(Hash)
          @layer.build_environment
        else
          {}
        end
      end

      def extract_package_manager
        (build_env['package_manager'] || build_env[:package_manager] || 'uv').to_s
      end

      def extract_extras
        Array(build_env['extras'] || build_env[:extras]).map(&:to_s)
      end

      def extract_index_url
        (build_env['index_url'] || build_env[:index_url])&.to_s
      end

      def only_binary?
        return build_env['only_binary'] ? true : false if build_env.key?('only_binary')
        return build_env[:only_binary] ? true : false if build_env.key?(:only_binary)

        true
      end

      def extract_layer_name
        @layer.respond_to?(:name) ? @layer.name.to_s : @layer.to_s
      end

      def resolve_python_versions
        runtimes = if @layer.respond_to?(:compatible_runtimes) && @layer.compatible_runtimes
                     Array(@layer.compatible_runtimes).map(&:to_s)
                   else
                     ['python3.12']
                   end
        py_rts = runtimes.select { |r| r.start_with?('python') }
        return ['python3.12'] if py_rts.empty?

        py_rts.map do |py_rt|
          m = py_rt.match(/python(\d+\.\d+)/)
          m ? "python#{m[1]}" : py_rt
        end.uniq
      end

      def extract_primary_architecture
        if @layer.respond_to?(:architectures) && @layer.architectures && !@layer.architectures.empty?
          @layer.architectures.first.to_s
        elsif @layer.respond_to?(:architecture) && @layer.architecture
          @layer.architecture.to_s
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
