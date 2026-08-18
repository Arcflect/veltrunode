# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'package_result'
require_relative 'layer_package_result'

module Veltrunode
  module Build
    class Cache
      DEFAULT_CACHE_DIR = '.veltrunode/cache'

      class << self
        def fetch(content_hash, output_path, cache_dir: nil)
          new(cache_dir: cache_dir).fetch(content_hash, output_path)
        end

        def store(content_hash, package_or_layer_result, cache_dir: nil)
          new(cache_dir: cache_dir).store(content_hash, package_or_layer_result)
        end

        def clear(cache_dir: nil)
          new(cache_dir: cache_dir).clear
        end
      end

      def initialize(cache_dir: nil)
        @cache_dir = File.expand_path(cache_dir || DEFAULT_CACHE_DIR)
      end

      HEX_HASH_PATTERN = /\A[0-9a-f]{64}\z/i

      def fetch(content_hash, output_path)
        key = content_hash.to_s
        return nil unless key.match?(HEX_HASH_PATTERN)

        cache_zip_path = zip_path_for(key)
        cache_json_path = json_path_for(key)

        return nil unless File.file?(cache_zip_path) && File.file?(cache_json_path)

        begin
          data = JSON.parse(File.read(cache_json_path))
        rescue JSON::ParserError
          invalidate!(key)
          return nil
        end

        recorded_sha256 = data['sha256']
        actual_sha256 = Digest::SHA256.file(cache_zip_path).hexdigest

        if recorded_sha256 != actual_sha256
          # Cache poisoning or corruption detected
          invalidate!(key)
          return nil
        end

        FileUtils.mkdir_p(File.dirname(output_path))
        FileUtils.cp(cache_zip_path, output_path)

        restore_result(data, output_path, key, actual_sha256)
      end

      def store(content_hash, package_or_layer_result)
        key = content_hash.to_s
        return unless key.match?(HEX_HASH_PATTERN)
        return unless package_or_layer_result && File.file?(package_or_layer_result.zip_path)

        FileUtils.mkdir_p(@cache_dir)

        cache_zip_path = zip_path_for(key)
        cache_json_path = json_path_for(key)

        FileUtils.cp(package_or_layer_result.zip_path, cache_zip_path)

        metadata = build_metadata(package_or_layer_result, key)
        File.write(cache_json_path, JSON.pretty_generate(metadata))
      end

      def clear
        return unless File.directory?(@cache_dir)

        FileUtils.rm_rf(@cache_dir)
      end

      private

      def zip_path_for(content_hash)
        File.join(@cache_dir, "#{content_hash}.zip")
      end

      def json_path_for(content_hash)
        File.join(@cache_dir, "#{content_hash}.json")
      end

      def invalidate!(content_hash)
        FileUtils.rm_f(zip_path_for(content_hash))
        FileUtils.rm_f(json_path_for(content_hash))
      end

      def build_metadata(result, content_hash)
        if result.respond_to?(:layer_name)
          {
            'type' => 'layer',
            'content_hash' => content_hash,
            'sha256' => result.sha256,
            'layer_name' => result.layer_name,
            'compressed_size' => result.compressed_size,
            'uncompressed_size' => result.uncompressed_size,
            'size_diagnostics' => result.size_diagnostics,
            'entries' => result.entries,
            'diagnostics' => serialize_diagnostics(result.diagnostics)
          }
        else
          {
            'type' => 'function',
            'content_hash' => content_hash,
            'sha256' => result.sha256,
            'function_name' => result.function_name,
            'bytesize' => result.bytesize,
            'entries' => result.entries,
            'diagnostics' => serialize_diagnostics(result.diagnostics)
          }
        end
      end

      def serialize_diagnostics(diagnostics)
        Array(diagnostics).map do |d|
          d.respond_to?(:to_h) ? d.to_h : d
        end
      end

      def restore_result(data, output_path, content_hash, actual_sha256)
        if data['type'] == 'layer'
          LayerPackageResult.new(
            layer_name: data['layer_name'],
            zip_path: output_path,
            content_hash: content_hash,
            sha256: actual_sha256,
            compressed_size: data['compressed_size'],
            uncompressed_size: data['uncompressed_size'],
            size_diagnostics: symbolize_keys(data['size_diagnostics']),
            entries: data['entries'],
            diagnostics: data['diagnostics'] || [],
            cached: true
          )
        else
          PackageResult.new(
            function_name: data['function_name'],
            zip_path: output_path,
            content_hash: content_hash,
            sha256: actual_sha256,
            bytesize: data['bytesize'],
            entries: data['entries'],
            diagnostics: data['diagnostics'] || [],
            cached: true
          )
        end
      end

      def symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), memo|
            memo[k.to_sym] = symbolize_keys(v)
          end
        when Array
          obj.map { |v| symbolize_keys(v) }
        else
          obj
        end
      end
    end
  end
end
