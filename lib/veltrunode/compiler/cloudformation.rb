# frozen_string_literal: true

require_relative 'cloudformation/function_compiler'
require_relative 'cloudformation/layer_version_compiler'
require_relative 'cloudformation/log_group_compiler'
require_relative 'cloudformation/queue_compiler'
require_relative 'cloudformation/role_compiler'
require_relative 'cloudformation/schedule_compiler'
require_relative 'cloudformation/template_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      class << self
        def compile(application, **)
          TemplateCompiler.compile(application, **)
        end

        def to_yaml(application, **)
          TemplateCompiler.to_yaml(application, **)
        end

        def generate(application, output_path: 'build/template.yml', **)
          TemplateCompiler.generate(application, output_path: output_path, **)
        end
      end
    end
  end
end
