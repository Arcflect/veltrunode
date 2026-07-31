# frozen_string_literal: true

module Veltrunode
  class ValidationError < Error
    attr_reader :diagnostics

    def initialize(message = nil, diagnostics: [])
      @diagnostics = diagnostics.dup.freeze
      super(message)
    end
  end

  module Validation
  end
end
