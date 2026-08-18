# frozen_string_literal: true

module Veltrunode
  module Build
    class LayerPackageResult
      attr_reader :layer_name,
                  :zip_path,
                  :content_hash,
                  :sha256,
                  :compressed_size,
                  :uncompressed_size,
                  :size_diagnostics,
                  :entries,
                  :diagnostics,
                  :cached

      def initialize(
        layer_name:,
        zip_path:,
        content_hash:,
        sha256:,
        compressed_size:,
        uncompressed_size:,
        size_diagnostics:,
        entries:,
        diagnostics: [],
        cached: false
      )
        @layer_name = layer_name.to_s.freeze
        @zip_path = zip_path.to_s.freeze
        @content_hash = content_hash.to_s.freeze
        @sha256 = sha256.to_s.freeze
        @compressed_size = compressed_size.to_i
        @uncompressed_size = uncompressed_size.to_i
        @size_diagnostics = size_diagnostics.freeze
        @entries = Array(entries).map(&:to_s).freeze
        @diagnostics = Array(diagnostics).freeze
        @cached = cached ? true : false

        freeze
      end

      def digest
        @sha256
      end

      def bytesize
        @compressed_size
      end

      def cached?
        @cached
      end
    end
  end
end
