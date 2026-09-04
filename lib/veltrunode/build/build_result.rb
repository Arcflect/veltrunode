# frozen_string_literal: true

module Veltrunode
  module Build
    class BuildResult
      attr_reader :application,
                  :function_results,
                  :layer_results,
                  :template_path,
                  :template_data,
                  :manifest_path,
                  :manifest_data,
                  :diagnostics

      def initialize(
        application:,
        function_results:,
        layer_results:,
        template_path:,
        template_data:,
        manifest_path:,
        manifest_data:,
        diagnostics: []
      )
        @application = application
        @function_results = Array(function_results).freeze
        @layer_results = Array(layer_results).freeze
        @template_path = template_path.to_s.freeze
        @template_data = (template_data || {}).freeze
        @manifest_path = manifest_path.to_s.freeze
        @manifest_data = (manifest_data || {}).freeze
        @diagnostics = Array(diagnostics).freeze

        freeze
      end

      def functions_count
        @function_results.size
      end

      def layers_count
        @layer_results.size
      end

      def artifacts
        {
          'functions' => @function_results.map do |res|
            {
              'name' => res.function_name,
              'zip_path' => res.zip_path,
              'sha256' => res.sha256,
              'content_hash' => res.content_hash,
              'bytesize' => res.bytesize,
              'cached' => res.cached?
            }
          end,
          'layers' => @layer_results.map do |res|
            {
              'name' => res.layer_name,
              'zip_path' => res.zip_path,
              'sha256' => res.sha256,
              'content_hash' => res.content_hash,
              'bytesize' => res.bytesize,
              'cached' => res.cached?
            }
          end,
          'template' => {
            'path' => @template_path
          },
          'manifest' => {
            'path' => @manifest_path
          }
        }
      end

      def to_h
        {
          'status' => 'success',
          'message' => 'Build successful',
          'artifacts' => artifacts,
          'functions_count' => functions_count,
          'layers_count' => layers_count,
          'template_path' => @template_path,
          'manifest_path' => @manifest_path
        }
      end
    end
  end
end
