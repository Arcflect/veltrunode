# frozen_string_literal: true

require_relative 'veltrunode/version'
require_relative 'veltrunode/cli'
require_relative 'veltrunode/dsl'
require_relative 'veltrunode/model'
require_relative 'veltrunode/graph'
require_relative 'veltrunode/validation'
require_relative 'veltrunode/build'
require_relative 'veltrunode/compiler'
require_relative 'veltrunode/compiler/cloudformation'
require_relative 'veltrunode/aws'
require_relative 'veltrunode/aws/inspectors'
require_relative 'veltrunode/deploy'
require_relative 'veltrunode/diagnostics'
require_relative 'veltrunode/runner'
require_relative 'veltrunode/generator'

module Veltrunode
  class Error < StandardError; end

  class << self
    def application(name, &)
      @app = Veltrunode::DSL.evaluate(name, &)
    end

    def last_application
      @app
    end

    def reset!
      @app = nil
    end
  end
end
