# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'bundler'
require 'zip'
require_relative 'deterministic_archiver'
require_relative 'layer_package_result'
require_relative '../validation'

module Veltrunode
  module Build
    class LayerPackager
      DEFAULT_OUTPUT_DIR = 'build/artifacts/layers'
      BUILD_SCHEMA_VERSION = '1.0'

      RUNTIME_ABI_MAP = {
        'ruby3.3' => '3.3.0',
        'ruby3.2' => '3.2.0',
        'ruby3.1' => '3.1.0',
        'ruby3.0' => '3.0.0'
      }.freeze

      class << self
        def package(
          layer:,
          gemfile_lock_path: nil,
          source_dir: nil,
          output_dir: DEFAULT_OUTPUT_DIR,
          without_groups: %w[development test],
          groups: nil,
          include_gems: nil,
          build_image_id: nil,
          allow_missing_gems: false,
          includes: nil,
          excludes: nil
        )
          new(
            layer: layer,
            gemfile_lock_path: gemfile_lock_path,
            source_dir: source_dir,
            output_dir: output_dir,
            without_groups: without_groups,
            groups: groups,
            include_gems: include_gems,
            build_image_id: build_image_id,
            allow_missing_gems: allow_missing_gems,
            includes: includes,
            excludes: excludes
          ).package
        end
      end

      def initialize(
        layer:,
        gemfile_lock_path: nil,
        source_dir: nil,
        output_dir: DEFAULT_OUTPUT_DIR,
        without_groups: %w[development test],
        groups: nil,
        include_gems: nil,
        build_image_id: nil,
        allow_missing_gems: false,
        includes: nil,
        excludes: nil
      )
        @layer = layer
        @source_dir = source_dir ? File.expand_path(source_dir.to_s) : Dir.pwd
        @gemfile_lock_path = resolve_gemfile_lock_path(gemfile_lock_path)
        @output_dir = File.expand_path(output_dir.to_s)
        @without_groups = Array(without_groups).map(&:to_s)
        @groups = groups ? Array(groups).map(&:to_s) : []
        @include_gems = include_gems ? Array(include_gems).map(&:to_s) : []
        @build_image_id = build_image_id ? build_image_id.to_s : 'amazonlinux:default'
        @allow_missing_gems = allow_missing_gems
        @user_includes = includes ? Array(includes).map(&:to_s) : []
        @user_excludes = excludes ? Array(excludes).map(&:to_s) : []
      end

      def package
        layer_name = extract_layer_name
        lock_content = read_gemfile_lock
        content_hash = calculate_content_hash(lock_content)

        ruby_abi_version = resolve_ruby_abi_version

        Dir.mktmpdir('veltrunode_layer_') do |tmp_dir|
          layer_gems_dir = File.join(tmp_dir, 'ruby', 'gems', ruby_abi_version)
          stage_gems_into_structure(lock_content, layer_gems_dir)

          zip_path = File.join(@output_dir, "#{layer_name}.zip")
          archive_result = DeterministicArchiver.archive(
            source_dir: tmp_dir,
            output_path: zip_path,
            includes: @user_includes.empty? ? nil : @user_includes,
            excludes: @user_excludes.empty? ? nil : @user_excludes
          )

          size_diag = calculate_size_diagnostics(archive_result.output_path)

          LayerPackageResult.new(
            layer_name: layer_name,
            zip_path: archive_result.output_path,
            content_hash: content_hash,
            sha256: archive_result.sha256,
            compressed_size: archive_result.bytesize,
            uncompressed_size: size_diag[:uncompressed_size],
            size_diagnostics: size_diag,
            entries: archive_result.entries,
            diagnostics: []
          )
        end
      end

      private

      def resolve_gemfile_lock_path(path)
        if path
          File.expand_path(path.to_s)
        else
          candidate = File.join(@source_dir, 'Gemfile.lock')
          File.exist?(candidate) ? candidate : nil
        end
      end

      def extract_layer_name
        if @layer.respond_to?(:name)
          @layer.name
        else
          @layer.to_s
        end
      end

      def extract_runtimes
        if @layer.respond_to?(:compatible_runtimes) && @layer.compatible_runtimes
          Array(@layer.compatible_runtimes).map(&:to_s)
        else
          ['ruby3.3']
        end
      end

      def extract_architectures
        if @layer.respond_to?(:architectures) && @layer.architectures
          Array(@layer.architectures).map(&:to_s)
        else
          ['x86_64']
        end
      end

      def resolve_ruby_abi_version
        runtimes = extract_runtimes
        runtimes.each do |r|
          return RUNTIME_ABI_MAP[r] if RUNTIME_ABI_MAP.key?(r)
        end
        '3.3.0'
      end

      def read_gemfile_lock
        unless @gemfile_lock_path && File.file?(@gemfile_lock_path)
          target = @gemfile_lock_path || File.join(@source_dir, 'Gemfile.lock')
          raise ValidationError, "Gemfile.lock not found: #{target}"
        end

        File.read(@gemfile_lock_path)
      end

      def calculate_content_hash(lock_content)
        raw = [
          "schema_version:#{BUILD_SCHEMA_VERSION}",
          "gemfile_lock:#{lock_content}",
          "groups:#{@groups.sort.join(',')}",
          "without_groups:#{@without_groups.sort.join(',')}",
          "runtimes:#{extract_runtimes.sort.join(',')}",
          "architectures:#{extract_architectures.sort.join(',')}",
          "build_image_id:#{@build_image_id}",
          "include_gems:#{@include_gems.sort.join(',')}",
          "includes:#{@user_includes.sort.join(',')}",
          "excludes:#{@user_excludes.sort.join(',')}"
        ].join("\n")

        Digest::SHA256.hexdigest(raw)
      end

      def parse_lockfile_specs(lock_content)
        return [] if lock_content.strip.empty?

        parser = Bundler::LockfileParser.new(lock_content)
        specs = parser.specs

        if specs.empty? && lock_content.match?(/(?:GEM|DEPENDENCIES|PLATFORMS|INVALID)/i)
          raise ValidationError, 'Failed to parse Gemfile.lock: lockfile content is invalid'
        end

        specs = filter_specs_by_groups(specs)
        specs = specs.select { |spec| @include_gems.include?(spec.name) } if @include_gems.any?

        specs
      rescue ValidationError
        raise
      rescue StandardError => e
        raise ValidationError, "Failed to parse Gemfile.lock: #{e.message}"
      end

      def filter_specs_by_groups(specs)
        return specs if @groups.empty? && @without_groups.empty?

        groups_map = parse_gemfile_groups(resolve_gemfile_path)

        specs.reject do |spec|
          gem_groups = groups_map[spec.name] || ['default']
          if @groups.any?
            !gem_groups.intersect?(@groups)
          else
            gem_groups.intersect?(@without_groups)
          end
        end
      end

      def parse_gemfile_groups(gemfile_path)
        return {} unless gemfile_path && File.exist?(gemfile_path)

        groups_map = {}
        current_groups = ['default']

        File.foreach(gemfile_path) do |line|
          stripped = line.strip
          next if stripped.start_with?('#')

          case stripped
          when /\Agroup\s+(.+)\s+do\b/
            current_groups = Regexp.last_match(1).split(',').map { |g| g.strip.delete_prefix(':') }
          when 'end'
            current_groups = ['default']
          when /\Agem\s+['"]([^'"]+)['"]/
            gem_name = Regexp.last_match(1)
            groups_map[gem_name] = current_groups
          end
        end

        groups_map
      end

      def resolve_gemfile_path
        if @gemfile_lock_path
          dir = File.dirname(@gemfile_lock_path)
          candidate = File.join(dir, 'Gemfile')
          return candidate if File.exist?(candidate)
        end

        candidate = File.join(@source_dir, 'Gemfile')
        File.exist?(candidate) ? candidate : nil
      end

      def stage_gems_into_structure(lock_content, layer_gems_dir)
        gems_dir = File.join(layer_gems_dir, 'gems')
        specs_dir = File.join(layer_gems_dir, 'specifications')

        FileUtils.mkdir_p(gems_dir)
        FileUtils.mkdir_p(specs_dir)

        specs = parse_lockfile_specs(lock_content)
        specs.each do |spec|
          gem_full_name = "#{spec.name}-#{spec.version}"
          gem_dir = File.join(gems_dir, gem_full_name)
          gemspec_file = File.join(specs_dir, "#{gem_full_name}.gemspec")

          FileUtils.mkdir_p(gem_dir)
          copy_gem_contents_if_available(spec.name, spec.version, gem_dir)

          next if File.exist?(gemspec_file)

          dummy_gemspec = <<~GEMSPEC
            Gem::Specification.new do |s|
              s.name = #{spec.name.dump}
              s.version = #{spec.version.to_s.dump}
              s.summary = "Layer gem #{spec.name}"
            end
          GEMSPEC
          File.write(gemspec_file, dummy_gemspec)
        end
      end

      def copy_gem_contents_if_available(name, version, target_dir)
        source_gem_dir = find_local_gem_dir(name, version)
        if source_gem_dir.nil? || !File.directory?(source_gem_dir)
          unless @allow_missing_gems
            raise ValidationError, "Gem content not found for '#{name}' (#{version}). " \
                                   "Ensure gems are installed in '#{@source_dir}' or system."
          end

          return
        end

        begin
          FileUtils.cp_r(File.join(source_gem_dir, '.'), target_dir)
        rescue StandardError => e
          raise ValidationError, "Failed to copy gem '#{name}' (#{version}): #{e.message}"
        end
      end

      def find_local_gem_dir(name, version)
        # Check source_dir vendor/bundle or gems
        candidates = [
          File.join(@source_dir, 'vendor', 'bundle', 'ruby', '*', 'gems', "#{name}-#{version}"),
          File.join(@source_dir, 'gems', "#{name}-#{version}"),
          File.join(@source_dir, name)
        ]

        candidates.each do |pattern|
          matches = Dir.glob(pattern)
          return matches.first if matches.any? && File.directory?(matches.first)
        end

        begin
          spec = Gem::Specification.find_by_name(name, version.to_s)
          spec&.full_gem_path
        rescue StandardError, ScriptError
          nil
        end
      end

      def calculate_size_diagnostics(zip_path)
        uncompressed_size = 0
        entry_count = 0
        entries_with_size = []

        Zip::File.open(zip_path) do |zip|
          entry_count = zip.size
          zip.each do |entry|
            next if entry.directory?

            uncompressed_size += entry.size
            entries_with_size << { 'path' => entry.name, 'size' => entry.size }
          end
        end

        largest_entries = entries_with_size.sort_by { |e| -e['size'] }.first(5)

        {
          compressed_size: File.size(zip_path),
          uncompressed_size: uncompressed_size,
          entry_count: entry_count,
          largest_entries: largest_entries
        }
      end
    end
  end
end
