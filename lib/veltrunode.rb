require_relative "veltrunode/version"
require_relative "veltrunode/model"
require_relative "veltrunode/dsl"
require_relative "veltrunode/runner"

module Veltrunode
  class Error < StandardError; end

  class << self
    def application(name, &block)
      @app = Veltrunode::DSL.evaluate(name, &block)
    end

    def last_application
      @app
    end

    def reset!
      @app = nil
    end
  end
end
