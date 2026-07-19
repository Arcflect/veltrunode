# frozen_string_literal: true

require 'json'
require_relative 'error_code_registry'

module Veltrunode
  module Diagnostics
    class Diagnostic
      SEVERITIES = %i[error warning info].freeze

      attr_reader :code, :severity, :summary, :evidence,
                  :source_path, :suggested_action, :aws_resource_id

      def initialize(code:, severity:, summary:, suggested_action:, evidence: {}, source_path: nil, aws_resource_id: nil)
        @code = normalize_code(code)
        @severity = normalize_severity(severity)
        @summary = normalize_text(summary, field_name: 'summary')
        @suggested_action = normalize_text(suggested_action, field_name: 'suggested_action')
        @evidence = normalize_evidence(evidence)
        @source_path = optional_text(source_path)
        @aws_resource_id = optional_text(aws_resource_id)

        freeze
      end

      def to_h
        {
          code: code,
          severity: severity,
          summary: summary,
          evidence: evidence,
          source_path: source_path,
          suggested_action: suggested_action,
          aws_resource_id: aws_resource_id
        }
      end

      def to_json(*_args)
        JSON.generate(to_h)
      end

      def to_text
        lines = []
        lines << "[#{severity.to_s.upcase}] #{code}: #{summary}"
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
         unless severity.respond_to?(:to_sym)
           raise ArgumentError, "severity must be one of: #{SEVERITIES.join(', ')}"
         end
        value = severity.to_sym
        return value if SEVERITIES.include?(value)
      end

      def normalize_text(value, field_name:)
        text = String(value).strip
        raise ArgumentError, "#{field_name} must not be empty" if text.empty?

        text
      end

      def optional_text(value)
        return nil if value.nil?

        normalize_text(value, field_name: 'optional field')
      end

      def normalize_evidence(evidence)
        value = evidence || {}
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
