# frozen_string_literal: true

require_relative 'deterministic_archiver'
require_relative 'package_result'
require_relative 'secret_scanner'
require_relative '../validation'

module Veltrunode
  module Build
    class FunctionPackager
      DEFAULT_OUTPUT_DIR = 'build/artifacts/functions'
      DEFAULT_EXCLUDES = %w[
        spec/* test/* spec/**/* test/**/* *.tmp
        .git/* .git/**/* .DS_Store tmp/* tmp/**/* *.log
      ].freeze

      class << self
        def package(function:, source_dir:, output_dir: DEFAULT_OUTPUT_DIR, includes: nil, excludes: nil)
          new(
            function: function,
            source_dir: source_dir,
            output_dir: output_dir,
            includes: includes,
            excludes: excludes
          ).package
        end
      end

      def initialize(function:, source_dir:, output_dir: DEFAULT_OUTPUT_DIR, includes: nil, excludes: nil)
        @function = function
        @source_dir = File.expand_path(source_dir.to_s)
        @output_dir = File.expand_path(output_dir.to_s)
        @user_includes = includes ? Array(includes).map(&:to_s) : []
        @user_excludes = excludes ? Array(excludes).map(&:to_s) : []
      end

      def package
        fn_name = extract_function_name
        handler_str = extract_handler

        validate_handler_file!(fn_name, handler_str)

        zip_path = File.join(@output_dir, "#{fn_name}.zip")
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

        PackageResult.new(
          function_name: fn_name,
          zip_path: archive_result.output_path,
          sha256: archive_result.sha256,
          bytesize: archive_result.bytesize,
          entries: archive_result.entries,
          diagnostics: scanner_diagnostics
        )
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
          code: 'VLT-BUILD-001',
          severity: :error,
          summary: "Handler file not found for function '#{fn_name}': expected one of #{expected_files.join(', ')}.",
          suggested_action: 'Ensure the handler file exists in source directory ' \
                            "'#{@source_dir}' (handler: '#{handler_str}').",
          evidence: { 'function' => fn_name, 'handler' => handler_str, 'expected_files' => expected_files }
        )
        raise ValidationError.new(diag.summary, diagnostics: [diag])
      end
    end
  end
end
