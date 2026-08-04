# frozen_string_literal: true

module Veltrunode
  module Model
    class Capability
      attr_reader :type, :params

      def initialize(type:, params: {})
        raise ValidationError, 'Capability type is required' if type.nil? || type.to_s.strip.empty?

        @type = type.to_s.to_sym
        @params = freeze_hash(params)

        freeze
      end

      private

      def freeze_value(val)
        case val
        when Hash
          freeze_hash(val)
        when Array
          val.map { |item| freeze_value(item) }.freeze
        when String
          val.dup.freeze
        else
          val.frozen? ? val : val.freeze
        end
      end

      def freeze_hash(hash)
        return {}.freeze if hash.nil?

        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.to_sym] = freeze_value(v)
        end.freeze
      end
    end
  end
end
