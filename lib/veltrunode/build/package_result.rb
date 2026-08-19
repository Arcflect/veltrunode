# frozen_string_literal: true

module Veltrunode
  module Build
    class PackageResult
      attr_reader :function_name, :zip_path, :content_hash, :sha256, :bytesize, :entries, :diagnostics, :cached

      def initialize(function_name:, zip_path:, sha256:, bytesize:, entries:, diagnostics: [], content_hash: nil,
                     cached: false)
        @function_name = function_name.to_s.freeze
        @zip_path = zip_path.to_s.freeze
        @content_hash = (content_hash || sha256).to_s.freeze
        @sha256 = sha256.to_s.freeze
        @bytesize = bytesize.to_i
        @entries = Array(entries).map(&:to_s).freeze
        @diagnostics = Array(diagnostics).freeze
        @cached = cached ? true : false

        freeze
      end

      def digest
        @sha256
      end

      def cached?
        @cached
      end
    end
  end
end
