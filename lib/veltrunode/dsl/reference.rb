# frozen_string_literal: true

module Veltrunode
  module DSL
    class Reference
      attr_reader :name

      def initialize(name)
        @name = name.to_s.to_sym
        freeze
      end

      def to_s
        @name.to_s
      end

      def inspect
        "ref(:#{@name})"
      end

      def ==(other)
        other.is_a?(Reference) && name == other.name
      end
    end
  end
end
