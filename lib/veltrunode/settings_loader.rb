# frozen_string_literal: true

module Veltrunode
  class SettingsLoader
    DEFAULT_FILE = 'Veltrunodefile'
    DEFAULT_EXIT_CODE = 2

    class LoadError < StandardError
      attr_reader :exit_code, :diagnostic

      def initialize(diagnostic, exit_code: DEFAULT_EXIT_CODE)
        super(diagnostic.to_text)
        @diagnostic = diagnostic
        @exit_code = exit_code
      end
    end

    def self.load(file_path: DEFAULT_FILE)
      new(file_path:).load
    end

    def initialize(file_path:)
      path = file_path.to_s
      @file_path = path.empty? ? DEFAULT_FILE : path
    end

    def load
      absolute_path = File.expand_path(@file_path)
      unless File.file?(absolute_path)
        raise_load_error(
          code: 'VLT-DSL-001',
          summary: "Configuration file was not found: #{@file_path}",
          suggested_action: "Create #{@file_path} or pass --file with a valid path.",
          source_path: @file_path
        )
      end

      source = File.read(absolute_path)
      evaluate_source(source, absolute_path)
    rescue SystemCallError => e
      raise_load_error(
        code: 'VLT-DSL-001',
        summary: "Configuration file could not be read: #{@file_path}",
        suggested_action: 'Check the file path and permissions and retry.',
        evidence: { error_class: e.class.name },
        source_path: @file_path
      )
    end

    private

    def evaluate_source(source, source_path)
      Veltrunode.reset!
      # rubocop:disable Security/Eval
      Kernel.eval(source, TOPLEVEL_BINDING, source_path, 1)
      # rubocop:enable Security/Eval

      application = Veltrunode.last_application
      return application if application

      raise_load_error(
        code: 'VLT-DSL-003',
summary: "Configuration evaluation failed in #{source_path}: no application was defined (Veltrunode.application was not called).",
        suggested_action: 'Define the application via Veltrunode.application in the configuration file.',
        source_path:
      )
    rescue SyntaxError => e
      line_number = extract_line_number(e.message, source_path)
      raise_load_error(
        code: 'VLT-DSL-002',
        summary: syntax_error_summary(source_path, line_number),
        suggested_action: 'Fix the Ruby syntax error in the configuration file and retry.',
        evidence: { error: first_line(e.message) },
        source_path:
      )
    rescue LoadError
      raise
    rescue StandardError => e
      line_number = extract_line_number(Array(e.backtrace).join("\n"), source_path)
      raise_load_error(
        code: 'VLT-DSL-003',
        summary: evaluation_error_summary(source_path, line_number, e.message),
        suggested_action: 'Fix the DSL expression and retry.',
        evidence: { error_class: e.class.name },
        source_path:
      )
    end

    def syntax_error_summary(source_path, line_number)
      base = "Configuration syntax error in #{source_path}"
      return "#{base} at line #{line_number}." if line_number

      "#{base}."
    end

    def evaluation_error_summary(source_path, line_number, message)
      base = "Configuration evaluation failed in #{source_path}"
      location = line_number ? " at line #{line_number}" : ''
      "#{base}#{location}: #{message}"
    end

    def extract_line_number(text, source_path)
      escaped = Regexp.escape(source_path)
      text[/#{escaped}:(\d+)/, 1]&.to_i
    end

    def first_line(text)
      text.to_s.lines.first.to_s.strip
    end

    def raise_load_error(code:, summary:, suggested_action:, evidence: {}, source_path: nil)
      diagnostic = Veltrunode::Diagnostics::Diagnostic.new(
        code:,
        severity: :error,
        summary:,
        suggested_action:,
        evidence:,
        source_path:
      )
      raise LoadError, diagnostic
    end
  end
end
