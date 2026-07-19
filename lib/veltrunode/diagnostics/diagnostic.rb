# frozen_string_literal: true

require 'json'
require_relative 'error_code_registry'

module Veltrunode
  module Diagnostics
    class Diagnostic
      SEVERITIES = %i[error warning info].freeze

      attr_reader :code, :severity, :summary, :evidence,
                  :source_path, :suggested_action, :aws_resource_id

      def initialize(code:, severity:, summary:, suggested_action:, **options)
        evidence = options.key?(:evidence) ? options.delete(:evidence) : {}
        source_path = options.delete(:source_path)
        aws_resource_id = options.delete(:aws_resource_id)
        raise ArgumentError, "unknown keyword(s): #{options.keys.join(', ')}" unless options.empty?

        @code = normalize_code(code)
        @severity = normalize_severity(severity)
        @summary = normalize_text(summary, field_name: 'summary')
        @suggested_action = normalize_text(suggested_action, field_name: 'suggested_action')
        @evidence = normalize_evidence(evidence)
        @source_path = optional_text(source_path, field_name: 'source_path')
        @aws_resource_id = optional_text(aws_resource_id, field_name: 'aws_resource_id')

        freeze
      end

      def to_h
        {
          code:,
          severity:,
          summary:,
          evidence:,
          source_path:,
          suggested_action:,
          aws_resource_id:
        }
      end

      def to_json(...)
        to_h.to_json(...)
      end

      def to_text
        lines = []
        lines << "#{code}: #{summary}"
        lines << "Severity: #{severity}"
        lines << "Suggested action: #{suggested_action}"
        lines << "Source path: #{source_path}" if source_path
        lines << "AWS resource: #{aws_resource_id}" if aws_resource_id

        unless evidence.empty?
          lines << 'Evidence:'
          evidence.each do |key, value|
            lines << "  - #{key}: #{format_value(value)}"
          end
        end

        lines.join("\n")
      end

      private

      def normalize_code(code)
        value = String(code).strip
        raise ArgumentError, 'code must not be empty' if value.empty?
        return value if ErrorCodeRegistry.valid?(value)

        raise ArgumentError, "invalid diagnostic code format: #{value.inspect}"
      end

      def normalize_severity(severity)
        raise ArgumentError, "severity must be one of: #{SEVERITIES.join(', ')}" unless severity.respond_to?(:to_sym)

        value = severity.to_sym
        return value if SEVERITIES.include?(value)

        raise ArgumentError, "severity must be one of: #{SEVERITIES.join(', ')}"
      end

      def normalize_text(value, field_name:)
        text = String(value).strip
        raise ArgumentError, "#{field_name} must not be empty" if text.empty?

        text
      end

      def optional_text(value, field_name:)
        return nil if value.nil?

        normalize_text(value, field_name:)
      end

      def normalize_evidence(evidence)
        value = evidence.nil? ? {} : evidence
        raise ArgumentError, 'evidence must be a Hash if provided' unless value.is_a?(Hash)

        deep_freeze(normalize_value(value))
      end

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), memo|
            memo[String(key)] = normalize_value(item)
          end
        when Array
          value.map { |item| normalize_value(item) }
        when String
          value.dup
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when Array
          value.each { |item| deep_freeze(item) }
        end

        value.freeze
      end

      def format_value(value)
        case value
        when Hash, Array
          JSON.generate(value)
        else
          value.inspect
        end
      end
    end
  end
end
