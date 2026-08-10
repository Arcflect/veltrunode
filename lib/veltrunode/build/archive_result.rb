# frozen_string_literal: true

module Veltrunode
  module Build
    class ArchiveResult
      attr_reader :output_path, :sha256, :entries, :bytesize

      def initialize(output_path:, sha256:, entries:, bytesize:)
        @output_path = output_path.to_s.freeze
        @sha256 = sha256.to_s.freeze
        @entries = Array(entries).map(&:to_s).freeze
        @bytesize = bytesize.to_i

        freeze
      end

      def digest
        @sha256
      end
    end
  end
end
