# frozen_string_literal: true

module Veltrunode
  module Build
    class PackageResult
      attr_reader :function_name, :zip_path, :content_hash, :sha256, :bytesize, :entries, :diagnostics, :cached,
                  :package_type, :image_uri, :image_tag, :dockerfile_path, :build_command

      def initialize(function_name:, zip_path:, sha256:, bytesize:, entries:, diagnostics: [], content_hash: nil,
                     cached: false, package_type: 'Zip', image_uri: nil, image_tag: nil, dockerfile_path: nil,
                     build_command: nil)
        @function_name = function_name.to_s.freeze
        @zip_path = zip_path.to_s.freeze
        @content_hash = (content_hash || sha256).to_s.freeze
        @sha256 = sha256.to_s.freeze
        @bytesize = bytesize.to_i
        @entries = Array(entries).map(&:to_s).freeze
        @diagnostics = Array(diagnostics).freeze
        @cached = cached ? true : false
        @package_type = (package_type || 'Zip').to_s.freeze
        @image_uri = image_uri&.to_s&.freeze
        @image_tag = image_tag&.to_s&.freeze
        @dockerfile_path = dockerfile_path&.to_s&.freeze
        @build_command = build_command ? Array(build_command).map(&:to_s).freeze : nil

        freeze
      end

      def digest
        @sha256
      end

      def cached?
        @cached
      end

      def image?
        @package_type == 'Image'
      end
    end
  end
end
