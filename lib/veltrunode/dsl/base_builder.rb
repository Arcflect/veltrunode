# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module DSL
    class BaseBuilder
      def method_missing(name, *args)
        diagnostic = Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-001',
          severity: :error,
          summary: "Undefined DSL method '#{name}' called in #{self.class.name.split('::').last}.",
          suggested_action: 'Check Veltrunodefile syntax for typos or unsupported DSL methods.',
          evidence: { 'method_name' => name.to_s, 'args' => args.map(&:to_s) }
        )
        raise ValidationError.new("Undefined DSL method '#{name}' (VLT-DSL-001)", diagnostics: [diagnostic])
      end

      def respond_to_missing?(_name, _include_private = false)
        false
      end

      private

      def env(name, secret: false)
        val = ENV.fetch(name.to_s, nil)
        secret ? SecretValue.new(val) : val
      end

      def ref(symbol)
        Reference.new(symbol)
      end
    end
  end
end
