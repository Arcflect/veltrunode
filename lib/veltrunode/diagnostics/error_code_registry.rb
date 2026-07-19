# frozen_string_literal: true

module Veltrunode
  module Diagnostics
    module ErrorCodeRegistry
      CATEGORY_CODES = %w[DSL REF GRAPH BUILD LAYER SCHED EFS AWS IAM CFN].freeze

      CATEGORY_PREFIXES = CATEGORY_CODES.map { |code| "VLT-#{code}-*".freeze }.freeze

      VALID_CODE_PATTERN = /\AVLT-(?:#{CATEGORY_CODES.join('|')})-[A-Z0-9]+(?:-[A-Z0-9]+)*\z/.freeze

      module_function

      def valid?(code)
        return false unless code.is_a?(String)

        VALID_CODE_PATTERN.match?(code)
      end

      def build(category, identifier)
        category_code = normalize_category(category)
        id = String(identifier).strip.upcase
        raise ArgumentError, 'identifier must not be empty' if id.empty?

        code = "VLT-#{category_code}-#{id}"
        return code if valid?(code)

        raise ArgumentError, "invalid identifier format for error code: #{identifier.inspect}"
      end

      def normalize_category(category)
        cat = String(category).strip.upcase
        return cat if CATEGORY_CODES.include?(cat)

        raise ArgumentError, "unknown error code category: #{category.inspect}"
      end
    end
  end
end
