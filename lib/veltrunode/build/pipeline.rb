# frozen_string_literal: true

require 'fileutils'
require_relative 'package_result'
require_relative 'layer_package_result'
require_relative 'function_packager'
require_relative 'layer_packager'
require_relative 'build_result'
require_relative '../compiler/cloudformation'
require_relative '../compiler/manifest'
require_relative '../validation/engine'

module Veltrunode
  module Build
    class BuildError < Veltrunode::Error
      attr_reader :exit_code

      def initialize(message, exit_code: 5)
        super(message)
        @exit_code = exit_code
      end
    end

    class Pipeline
      class << self
        def execute(application, source_dir: Dir.pwd, output_dir: nil, no_cache: false, skip_validation: false)
          new(
            application: application,
            source_dir: source_dir,
            output_dir: output_dir,
            no_cache: no_cache,
            skip_validation: skip_validation
          ).execute
        end
      end

      attr_reader :application, :source_dir, :output_dir, :no_cache, :skip_validation

      def initialize(application:, source_dir: Dir.pwd, output_dir: nil, no_cache: false, skip_validation: false)
        @application = application
        @source_dir = File.expand_path(source_dir.to_s.empty? ? Dir.pwd : source_dir.to_s)
        @output_dir = output_dir ? File.expand_path(output_dir.to_s) : File.join(@source_dir, 'build')
        @no_cache = no_cache ? true : false
        @skip_validation = skip_validation ? true : false
      end

      def execute
        # 1. Validation phase
        diagnostics = run_validation unless skip_validation

        # 2. Package Layers
        layer_output_dir = File.join(output_dir, 'artifacts', 'layers')
        layers = extract_collection(:layers)
        layer_results = layers.map do |layer|
          LayerPackager.package(
            layer: layer,
            source_dir: source_dir,
            output_dir: layer_output_dir,
            no_cache: no_cache
          )
        end

        # 3. Package Functions
        function_output_dir = File.join(output_dir, 'artifacts', 'functions')
        functions = extract_collection(:functions)
        function_results = functions.map do |fn|
          FunctionPackager.package(
            function: fn,
            source_dir: source_dir,
            output_dir: function_output_dir,
            no_cache: no_cache
          )
        end

        # 4. Compile CloudFormation Template
        template_path = File.join(output_dir, 'template.yml')
        template_data = Compiler::CloudFormation.generate(
          application,
          output_path: template_path
        )

        # 5. Compile Manifest
        manifest_path = File.join(output_dir, 'manifest.json')
        manifest_data = Compiler::Manifest.generate(
          application: application,
          function_results: function_results,
          layer_results: layer_results,
          output_path: manifest_path
        )

        # Combine diagnostics
        all_diagnostics = Array(diagnostics)
        layer_results.each { |res| all_diagnostics.concat(res.diagnostics) if res.respond_to?(:diagnostics) }
        function_results.each { |res| all_diagnostics.concat(res.diagnostics) if res.respond_to?(:diagnostics) }

        BuildResult.new(
          application: application,
          function_results: function_results,
          layer_results: layer_results,
          template_path: template_path,
          template_data: template_data,
          manifest_path: manifest_path,
          manifest_data: manifest_data,
          diagnostics: all_diagnostics
        )
      rescue Veltrunode::ValidationError
        raise
      rescue StandardError => e
        raise BuildError, "Build failed: #{e.message}"
      end

      private

      def run_validation
        diagnostics = Validation::Engine.run(application)
        errors = diagnostics.select { |d| d.severity == :error }

        return diagnostics if errors.empty?

        raise ValidationError.new("Validation failed with #{errors.size} error(s).", diagnostics: diagnostics)
      end

      def extract_collection(name)
        if application.respond_to?(name) && application.public_send(name)
          Array(application.public_send(name))
        elsif application.is_a?(Hash)
          Array(application[name.to_sym] || application[name.to_s])
        else
          []
        end
      end
    end
  end
end
