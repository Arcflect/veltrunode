# frozen_string_literal: true

require_relative 'dsl/secret_value'
require_relative 'dsl/reference'
require_relative 'dsl/base_builder'
require_relative 'dsl/permit_builder'
require_relative 'dsl/layer_builder'
require_relative 'dsl/efs_mount_builder'
require_relative 'dsl/function_builder'
require_relative 'dsl/schedule_builder'
require_relative 'dsl/application_builder'

module Veltrunode
  module DSL
    class << self
      def application(name, &)
        builder = ApplicationBuilder.new(name)
        builder.instance_eval(&) if block_given?
        builder.build
      end

      alias evaluate application

      def parse(content, filename = 'Veltrunodefile')
        normalized_content = preprocess_dsl_keywords(content)
        context = Module.new do
          extend Veltrunode::DSL
        end
        context.module_eval(normalized_content, filename, 1)
      end

      def load_file(path)
        raise ValidationError, "File not found: #{path}" unless File.exist?(path)

        content = File.read(path)
        parse(content, path)
      end

      private

      def preprocess_dsl_keywords(content)
        # Ruby 3.4 reserves 'retry' as a keyword. Normalize standalone 'retry ' to 'retry_policy '
        content.gsub(/(?<=^|\s)retry(?=\s)/, 'retry_policy')
      end
    end
  end
end
