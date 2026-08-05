# frozen_string_literal: true

module Veltrunode
  module DSL
    class SecretValue
      attr_reader :raw_value

      def initialize(raw_value)
        @raw_value = raw_value.to_s
        freeze
      end

      def to_s
        @raw_value
      end

      def inspect
        '[FILTERED]'
      end

      def secret?
        true
      end

      def ==(other)
        raw_value == if other.is_a?(SecretValue)
                       other.raw_value
                     else
                       other.to_s
                     end
      end
    end
  end
end
