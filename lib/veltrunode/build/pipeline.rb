# frozen_string_literal: true

require 'fileutils'
require_relative 'package_result'
require_relative 'layer_package_result'
require_relative 'function_packager'
require_relative 'layer_packager'
require_relative 'layer_reuse_evaluator'
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
        def execute(
          application,
          source_dir: Dir.pwd,
          output_dir: nil,
          no_cache: false,
          skip_validation: false,
          aws_client: nil,
          check_aws: true,
          check_manifest: true,
          allow_missing_gems: false
        )
          new(
            application: application,
            source_dir: source_dir,
            output_dir: output_dir,
            no_cache: no_cache,
            skip_validation: skip_validation,
            aws_client: aws_client,
            check_aws: check_aws,
            check_manifest: check_manifest,
            allow_missing_gems: allow_missing_gems
          ).execute
        end
      end

      attr_reader :application,
                  :source_dir,
                  :output_dir,
                  :no_cache,
                  :skip_validation,
                  :aws_client,
                  :check_aws,
                  :check_manifest,
                  :allow_missing_gems,
                  :build_logs

      def initialize(
        application:,
        source_dir: Dir.pwd,
        output_dir: nil,
        no_cache: false,
        skip_validation: false,
        aws_client: nil,
        check_aws: true,
        check_manifest: true,
        allow_missing_gems: false
      )
        @application = application
        @source_dir = File.expand_path(source_dir.to_s.empty? ? Dir.pwd : source_dir.to_s)
        @output_dir = output_dir ? File.expand_path(output_dir.to_s) : File.join(@source_dir, 'build')
        @no_cache = no_cache ? true : false
        @skip_validation = skip_validation ? true : false
        @aws_client = aws_client
        @check_aws = check_aws ? true : false
        @check_manifest = check_manifest ? true : false
        @allow_missing_gems = allow_missing_gems ? true : false
        @build_logs = []
      end

      def execute
        # 1. Validation phase
        diagnostics = run_validation unless skip_validation

        # 2. Package Layers (with reuse evaluation)
        layer_output_dir = File.join(output_dir, 'artifacts', 'layers')
        layers = extract_collection(:layers)
        existing_manifest_path = File.join(output_dir, 'manifest.json')

        reused_layers_map = {}
        layer_results = layers.map do |layer|
          layer_name = extract_layer_name(layer)

          # コンテンツハッシュベースの再利用判定
          decision = LayerReuseEvaluator.evaluate(
            layer,
            application: application,
            source_dir: source_dir,
            manifest_path: existing_manifest_path,
            aws_client: aws_client,
            check_aws: check_aws && !no_cache,
            check_manifest: check_manifest && !no_cache
          )

          if decision.reusable?
            # ハッシュ一致時は既存LayerバージョンARNを使用（新規発行・パッケージングをスキップ）
            reused_layers_map[layer_name] = decision.layer_version_arn
            log_reuse_decision(layer_name, decision)

            zip_candidate = File.join(layer_output_dir, "#{layer_name}.zip")
            compressed_sz = File.exist?(zip_candidate) ? File.size(zip_candidate) : 0
            LayerPackageResult.new(
              layer_name: layer_name,
              zip_path: zip_candidate,
              content_hash: decision.content_hash,
              sha256: decision.content_hash,
              compressed_size: compressed_sz,
              uncompressed_size: 0,
              size_diagnostics: {},
              entries: [],
              cached: true,
              reused: true,
              layer_version_arn: decision.layer_version_arn,
              reuse_decision: decision
            )
          else
            # ハッシュ不一致または検証不可能な場合は新規発行
            log_reuse_decision(layer_name, decision)

            pkg_opts = {
              layer: layer,
              source_dir: source_dir,
              output_dir: layer_output_dir,
              no_cache: no_cache
            }
            pkg_opts[:allow_missing_gems] = true if resolve_allow_missing_gems(layer)

            LayerPackager.package(**pkg_opts)
          end
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

        # 4. Compile CloudFormation Template (reused layers are skipped from LayerVersion resources)
        template_path = File.join(output_dir, 'template.yml')
        template_data = Compiler::CloudFormation.generate(
          application,
          output_path: template_path,
          context: { reused_layers: reused_layers_map }
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
          diagnostics: all_diagnostics,
          build_logs: @build_logs
        )
      rescue Veltrunode::ValidationError
        raise
      rescue StandardError => e
        raise BuildError, "Build failed: #{e.message}"
      end

      private

      def extract_layer_name(layer)
        if layer.respond_to?(:name)
          layer.name.to_s
        elsif layer.is_a?(Hash)
          (layer[:name] || layer['name']).to_s
        else
          layer.to_s
        end
      end

      def log_reuse_decision(layer_name, decision)
        msg = if decision.reusable?
                "[LAYER] Layer '#{layer_name}': Reusing existing version (ARN: #{decision.layer_version_arn}) " \
                  "via #{decision.source}"
              else
                "[LAYER] Layer '#{layer_name}': Publishing new version (#{decision.reason})"
              end
        @build_logs << msg
        $stdout.puts msg if ENV['VELTRUNODE_ENV'] == 'development'
      end

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

      def resolve_allow_missing_gems(layer)
        return true if @allow_missing_gems
        return false unless layer.respond_to?(:build_environment) && layer.build_environment.is_a?(Hash)

        layer.build_environment[:allow_missing_gems] || layer.build_environment['allow_missing_gems'] || false
      end
    end
  end
end
