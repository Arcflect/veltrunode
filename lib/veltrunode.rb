# frozen_string_literal: true

module Veltrunode
  class Error < StandardError; end

  class << self
    def application(name, &)
      @app = Veltrunode::DSL.application(name, &)
    end

    def parse(content, filename = 'Veltrunodefile')
      @app = Veltrunode::DSL.parse(content, filename)
    end

    def load_file(path)
      @app = Veltrunode::DSL.load_file(path)
    end

    def last_application
      @app
    end

    def reset!
      @app = nil
    end
  end
end

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
require_relative 'veltrunode/settings_loader'
require_relative 'veltrunode/runner'
require_relative 'veltrunode/generator'
