# frozen_string_literal: true

module Veltrunode
  module Build
    class PackageResult
      attr_reader :function_name, :zip_path, :sha256, :bytesize, :entries, :diagnostics

      def initialize(function_name:, zip_path:, sha256:, bytesize:, entries:, diagnostics: [])
        @function_name = function_name.to_s.freeze
        @zip_path = zip_path.to_s.freeze
        @sha256 = sha256.to_s.freeze
        @bytesize = bytesize.to_i
        @entries = Array(entries).map(&:to_s).freeze
        @diagnostics = Array(diagnostics).freeze

        freeze
      end

      def digest
        @sha256
      end
    end
  end
end
