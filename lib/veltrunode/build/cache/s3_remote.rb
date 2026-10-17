# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

module Veltrunode
  module Build
    class Cache
      # S3 をバックエンドとするリモートビルドキャッシュクライアント
      class S3Remote
        attr_reader :bucket, :prefix

        def initialize(bucket:, prefix: nil, s3_client: nil)
          @bucket = bucket.to_s.strip
          @prefix = normalize_prefix(prefix)
          @s3_client = s3_client
        end

        def fetch(content_hash, cache_dir, output_path)
          client = resolve_client
          return nil unless client

          json_key = key_for(content_hash, '.json')
          zip_key = key_for(content_hash, '.zip')

          Dir.mktmpdir('veltrunode_remote_cache_') do |tmp_dir|
            temp_json_path = File.join(tmp_dir, "#{content_hash}.json")
            temp_zip_path = File.join(tmp_dir, "#{content_hash}.zip")

            begin
              download_s3_file(client, json_key, temp_json_path)
              download_s3_file(client, zip_key, temp_zip_path)
            rescue StandardError
              # S3 キー不在、アクセス権限エラー、ネットワーク断などの場合は nil を返してビルド継続
              return nil
            end

            return nil unless File.file?(temp_json_path) && File.file?(temp_zip_path)

            begin
              data = JSON.parse(File.read(temp_json_path))
            rescue JSON::ParserError
              return nil
            end

            recorded_sha256 = data['sha256']
            actual_sha256 = Digest::SHA256.file(temp_zip_path).hexdigest

            # ハッシュ検証による汚染防止
            return nil if recorded_sha256 != actual_sha256

            # ローカルキャッシュディレクトリへ保存（ローカルとリモートの併用）
            FileUtils.mkdir_p(cache_dir)
            local_zip_path = File.join(cache_dir, "#{content_hash}.zip")
            local_json_path = File.join(cache_dir, "#{content_hash}.json")

            FileUtils.cp(temp_zip_path, local_zip_path)
            FileUtils.cp(temp_json_path, local_json_path)

            # 出力先へコピー
            FileUtils.mkdir_p(File.dirname(output_path))
            FileUtils.cp(temp_zip_path, output_path)

            [data, actual_sha256]
          end
        rescue StandardError
          nil
        end

        def store(content_hash, zip_path, json_path)
          return false unless File.file?(zip_path) && File.file?(json_path)

          client = resolve_client
          return false unless client

          zip_key = key_for(content_hash, '.zip')
          json_key = key_for(content_hash, '.json')

          File.open(zip_path, 'rb') do |zip_file|
            client.put_object(bucket: @bucket, key: zip_key, body: zip_file)
          end
          File.open(json_path, 'r') do |json_file|
            client.put_object(bucket: @bucket, key: json_key, body: json_file, content_type: 'application/json')
          end
          true
        rescue StandardError
          # リモートキャッシュへの保存失敗時もビルドは継続
          false
        end

        def key_for(content_hash, ext)
          clean_ext = ext.to_s.start_with?('.') ? ext.to_s : ".#{ext}"
          filename = "#{content_hash}#{clean_ext}"
          @prefix ? "#{@prefix}/#{filename}" : filename
        end

        private

        def normalize_prefix(prefix)
          return nil if prefix.nil?

          p = prefix.to_s.strip.gsub(%r{\A/+}, '').gsub(%r{/+\z}, '')
          p.empty? ? nil : p
        end

        def resolve_client
          return @s3_client if @s3_client

          require 'aws-sdk-s3' unless defined?(::Aws::S3::Client)
          ::Aws::S3::Client.new
        rescue LoadError, StandardError
          nil
        end

        def download_s3_file(client, key, dest_path)
          resp = client.get_object(bucket: @bucket, key: key, response_target: dest_path)
          return if File.file?(dest_path) && !File.empty?(dest_path)
          return unless resp.respond_to?(:body) && resp.body

          content = resp.body.respond_to?(:read) ? resp.body.read : resp.body.to_s
          File.binwrite(dest_path, content)
        end
      end
    end
  end
end
