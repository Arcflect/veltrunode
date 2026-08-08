# frozen_string_literal: true

require_relative 'validation/engine'

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
