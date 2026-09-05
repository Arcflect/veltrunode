# frozen_string_literal: true

require 'find'

require_relative 'deterministic_archiver'
require_relative 'package_result'
require_relative 'secret_scanner'
require_relative 'cache'
require_relative '../validation'

module Veltrunode
  module Build
    class FunctionPackager
      DEFAULT_OUTPUT_DIR = 'build/artifacts/functions'
      BUILD_SCHEMA_VERSION = '1.0'
      DEFAULT_EXCLUDES = %w[
        spec/* test/* spec/**/* test/**/* *.tmp
        .git/* .git/**/* .DS_Store tmp/* tmp/**/* *.log
        build/* build/**/* .veltrunode/* .veltrunode/**/*
      ].freeze

      class << self
        def package(function:, source_dir:, output_dir: DEFAULT_OUTPUT_DIR, includes: nil, excludes: nil,
                    no_cache: false, cache_dir: nil)
          new(
            function: function,
            source_dir: source_dir,
            output_dir: output_dir,
            includes: includes,
            excludes: excludes,
            no_cache: no_cache,
            cache_dir: cache_dir
          ).package
        end
      end

      def initialize(function:, source_dir:, output_dir: DEFAULT_OUTPUT_DIR, includes: nil, excludes: nil,
                     no_cache: false, cache_dir: nil)
        @function = function
        @source_dir = File.expand_path(source_dir.to_s)
        @output_dir = File.expand_path(output_dir.to_s)
        @user_includes = includes ? Array(includes).map(&:to_s) : []
        @user_excludes = excludes ? Array(excludes).map(&:to_s) : []
        @no_cache = no_cache
        @cache_dir = cache_dir ? File.expand_path(cache_dir.to_s) : File.join(@source_dir, '.veltrunode', 'cache')
      end

      def package
        fn_name = extract_function_name
        handler_str = extract_handler

        validate_handler_file!(fn_name, handler_str)
        validate_symlinks!

        content_hash = calculate_content_hash
        zip_path = File.join(@output_dir, "#{fn_name}.zip")

        unless @no_cache
          require_relative 'cache' unless defined?(Veltrunode::Build::Cache)
          cached_result = Cache.fetch(content_hash, zip_path, cache_dir: @cache_dir)
          return cached_result if cached_result
        end

        combined_excludes = (DEFAULT_EXCLUDES + @user_excludes).uniq

        archive_result = DeterministicArchiver.archive(
          source_dir: @source_dir,
          output_path: zip_path,
          includes: @user_includes.empty? ? nil : @user_includes,
          excludes: combined_excludes
        )

        scanner_diagnostics = SecretScanner.scan(
          source_dir: @source_dir,
          entries: archive_result.entries
        )

        result = PackageResult.new(
          function_name: fn_name,
          zip_path: archive_result.output_path,
          content_hash: content_hash,
          sha256: archive_result.sha256,
          bytesize: archive_result.bytesize,
          entries: archive_result.entries,
          diagnostics: scanner_diagnostics,
          cached: false
        )

        Cache.store(content_hash, result, cache_dir: @cache_dir) unless @no_cache

        result
      end

      def calculate_content_hash
        fn_name = extract_function_name
        handler_str = extract_handler
        runtime_str = @function.respond_to?(:runtime) ? @function.runtime : nil
        arch_str = @function.respond_to?(:architecture) ? @function.architecture : nil

        combined_excludes = (DEFAULT_EXCLUDES + @user_excludes).uniq
        entries = collect_and_filter_entries(combined_excludes)

        file_digests = entries.sort.map do |rel_path|
          abs_path = File.join(@source_dir, rel_path)
          if File.directory?(abs_path)
            "dir:#{rel_path}"
          else
            mode = File.file?(abs_path) && File.stat(abs_path).mode.anybits?(0o111) ? '755' : '644'
            sha = Digest::SHA256.file(abs_path).hexdigest
            "file:#{rel_path}:#{mode}:#{sha}"
          end
        end

        raw = [
          "schema_version:#{BUILD_SCHEMA_VERSION}",
          "function_name:#{fn_name}",
          "handler:#{handler_str}",
          "runtime:#{runtime_str}",
          "architecture:#{arch_str}",
          "includes:#{@user_includes.sort.join(',')}",
          "excludes:#{combined_excludes.sort.join(',')}",
          "files:\n#{file_digests.join("\n")}"
        ].join("\n")

        Digest::SHA256.hexdigest(raw)
      end

      private

      def extract_function_name
        if @function.respond_to?(:logical_name)
          @function.logical_name
        elsif @function.respond_to?(:name)
          @function.name
        else
          @function.to_s
        end
      end

      def extract_handler
        return nil unless @function.respond_to?(:handler)

        @function.handler
      end

      def validate_handler_file!(fn_name, handler_str)
        return if handler_str.nil? || handler_str.to_s.strip.empty?

        raw_str = handler_str.to_s.strip
        mod_path = raw_str.include?('.') ? raw_str.rpartition('.').first : raw_str
        return if mod_path.nil? || mod_path.empty?

        real_source_dir = File.exist?(@source_dir) ? File.realpath(@source_dir) : @source_dir
        base_prefix = real_source_dir.end_with?(File::SEPARATOR) ? real_source_dir : "#{real_source_dir}#{File::SEPARATOR}"
        candidate_extensions = ['', '.rb', '.py', '.js', '.mjs', '.cjs']
        found = candidate_extensions.any? do |ext|
          rel = "#{mod_path}#{ext}"
          abs = File.expand_path(rel, real_source_dir)
          abs = File.realpath(abs) if File.exist?(abs)
          next false unless abs.start_with?(base_prefix)

          File.file?(abs)
        end

        return if found

        expected_files = candidate_extensions.map { |ext| "#{mod_path}#{ext}" }
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-HANDLER-NOT-FOUND',
          severity: :error,
          summary: "Handler file not found for function '#{fn_name}': expected one of #{expected_files.join(', ')}.",
          suggested_action: 'Ensure the handler file exists in source directory ' \
                            "'#{@source_dir}' (handler: '#{handler_str}').",
          evidence: { 'function' => fn_name, 'handler' => handler_str, 'expected_files' => expected_files }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end

      def validate_symlinks!
        return unless File.directory?(@source_dir)

        real_source_dir = File.realpath(@source_dir)
        base_prefix = real_source_dir.end_with?(File::SEPARATOR) ? real_source_dir : "#{real_source_dir}#{File::SEPARATOR}"

        Find.find(@source_dir) do |abs_path|
          if File.directory?(abs_path) && (abs_path != @source_dir)
            basename = File.basename(abs_path)
            Find.prune if Validation::Engine::IGNORED_SCAN_DIRECTORIES.include?(basename)
          end

          next unless File.symlink?(abs_path)

          rel_path = abs_path.start_with?(base_prefix) ? abs_path.delete_prefix(base_prefix) : File.basename(abs_path)

          unless File.exist?(abs_path)
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-BUILD-SYMLINK-TRAVERSAL',
              severity: :error,
              summary: "Broken symlink found in source directory: '#{rel_path}'",
              suggested_action: "Remove broken symlink '#{rel_path}' from source directory '#{@source_dir}'.",
              evidence: { 'symlink' => rel_path }
            )
            raise ValidationError.new(diag.summary, diagnostics: [diag])
          end

          real_target = File.realpath(abs_path)
          next if real_target.start_with?(base_prefix)

          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-SYMLINK-TRAVERSAL',
            severity: :error,
            summary: "Symlink points outside source directory: '#{rel_path}' -> '#{real_target}'",
            suggested_action: 'Remove symlink pointing outside source directory ' \
                              "'#{@source_dir}' (symlink: '#{rel_path}').",
            evidence: { 'symlink' => rel_path, 'target' => real_target }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end
      end

      def collect_and_filter_entries(combined_excludes)
        return [] unless File.directory?(@source_dir)

        target_entries = []
        Dir.glob('**/*', File::FNM_DOTMATCH, base: @source_dir).each do |rel_path|
          next if %w[. ..].include?(rel_path)
          next if excluded?(rel_path, combined_excludes)
          next unless included?(rel_path)

          target_entries << rel_path
        end
        target_entries
      end

      def excluded?(rel_path, combined_excludes)
        combined_excludes.any? do |pat|
          clean_pat = pat.sub(%r{/\*\*$}, '').sub(%r{/\*$}, '')
          File.fnmatch?(pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?(pat, File.basename(rel_path), File::FNM_DOTMATCH) ||
            File.fnmatch?(clean_pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            rel_path.start_with?("#{clean_pat}/")
        end
      end

      def included?(rel_path)
        return true if @user_includes.empty? || @user_includes.include?('**/*')

        @user_includes.any? do |pat|
          clean_pat = pat.sub(%r{/\*\*$}, '').sub(%r{/\*$}, '')
          File.fnmatch?(pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?(pat, File.basename(rel_path), File::FNM_DOTMATCH) ||
            File.fnmatch?(clean_pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            rel_path.start_with?("#{clean_pat}/")
        end
      end
    end
  end
end
