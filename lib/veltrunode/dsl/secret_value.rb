# frozen_string_literal: true

module Veltrunode
  module DSL
    class SecretValue
      @registry = Set.new

      class << self
        def registry
          @registry ||= Set.new
        end

        def register(value)
          str = value.to_s
          registry.add(str) unless str.empty?
        end

        def clear_registry!
          @registry = Set.new
        end
      end

      attr_reader :raw_value

      def initialize(raw_value)
        @raw_value = raw_value.to_s
        self.class.register(@raw_value)
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
