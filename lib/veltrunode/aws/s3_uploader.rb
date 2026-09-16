# frozen_string_literal: true

require 'yaml'
require_relative '../compiler/logical_id'

module Veltrunode
  module AWS
    # S3 アップロードに関するエラー
    class S3UploadError < Veltrunode::Error
      attr_reader :bucket, :key, :original_error

      def initialize(message, bucket: nil, key: nil, original_error: nil)
        super(message)
        @bucket = bucket
        @key = key
        @original_error = original_error
      end
    end

    # S3 アップロード結果を表す値オブジェクト
    class UploadResult
      attr_reader :name, :bucket, :key, :status, :content_hash, :zip_path, :type

      def initialize(name:, bucket:, key:, status:, content_hash:, zip_path:, type: :function)
        @name = name.to_s.freeze
        @bucket = bucket.to_s.freeze
        @key = key.to_s.freeze
        @status = status.to_sym
        @content_hash = content_hash.to_s.freeze
        @zip_path = zip_path.to_s.freeze
        @type = type.to_sym
        freeze
      end

      def uploaded?
        @status == :uploaded
      end

      def skipped?
        @status == :skipped
      end

      def to_h
        {
          'name' => @name,
          'bucket' => @bucket,
          'key' => @key,
          'status' => @status.to_s,
          'content_hash' => @content_hash,
          'zip_path' => @zip_path,
          'type' => @type.to_s
        }
      end
    end

    # Lambda 関数および Layer の ZIP アーティファクトを S3 バケットへアップロードするクラス
    class S3Uploader
      attr_reader :bucket, :application, :prefix

      # @param bucket [String] アップロード先 S3 バケット名
      # @param application [Veltrunode::Model::Application, nil] アプリケーションモデル
      # @param s3_client [Aws::S3::Client, nil] S3 クライアント（DI 用）
      # @param prefix [String] S3 キープレフィックス
      def initialize(bucket:, application: nil, s3_client: nil, prefix: 'veltrunode')
        raise ArgumentError, 'S3 bucket name must be provided' if bucket.to_s.strip.empty?

        @bucket = bucket.to_s.strip.freeze
        @application = application
        @s3_client = s3_client
        @prefix = prefix.to_s.strip.empty? ? 'veltrunode' : prefix.to_s.strip.freeze
      end

      # S3 キーを生成します
      # 形式: #{prefix}/#{app}/#{stage}/#{hash}/#{name}.zip
      def generate_key(name:, content_hash:, ext: '.zip')
        hash_val = content_hash.to_s.strip
        raise ArgumentError, 'Content hash must be provided' if hash_val.empty?
        raise ArgumentError, 'Artifact name must be provided' if name.to_s.strip.empty?

        clean_ext = ext.to_s.start_with?('.') ? ext.to_s : ".#{ext}"
        "#{@prefix}/#{resolve_app_name}/#{resolve_stage_name}/#{hash_val}/#{name}#{clean_ext}"
      end

      # 指定されたファイルが既に S3 上に同一ハッシュで存在するか確認し、
      # 存在しない場合のみアップロードを実行します
      def upload_file(file_path:, name:, content_hash:, type: :function)
        abs_path = File.expand_path(file_path.to_s)
        unless File.file?(abs_path)
          raise S3UploadError.new("Artifact file '#{abs_path}' does not exist.", bucket: @bucket)
        end

        key = generate_key(name: name, content_hash: content_hash)

        if already_exists?(key)
          return UploadResult.new(
            name: name,
            bucket: @bucket,
            key: key,
            status: :skipped,
            content_hash: content_hash,
            zip_path: abs_path,
            type: type
          )
        end

        execute_put_object(abs_path, key)

        UploadResult.new(
          name: name,
          bucket: @bucket,
          key: key,
          status: :uploaded,
          content_hash: content_hash,
          zip_path: abs_path,
          type: type
        )
      end

      # BuildResult に含まれる関数および Layer アーティファクトを一括アップロードします
      def upload_build_result(build_result)
        results = []

        if build_result.respond_to?(:function_results)
          build_result.function_results.each do |fn_res|
            results << upload_file(
              file_path: fn_res.zip_path,
              name: fn_res.function_name,
              content_hash: fn_res.content_hash || fn_res.sha256,
              type: :function
            )
          end
        end

        if build_result.respond_to?(:layer_results)
          build_result.layer_results.each do |layer_res|
            results << upload_file(
              file_path: layer_res.zip_path,
              name: layer_res.layer_name,
              content_hash: layer_res.content_hash || layer_res.sha256,
              type: :layer
            )
          end
        end

        results
      end

      # CloudFormation テンプレート内の Code.S3Bucket/S3Key (関数) および
      # Content.S3Bucket/S3Key (Layer) をアップロード後の S3 参照に更新します
      def update_template(template_data_or_path, upload_results:)
        template_hash = load_template_hash(template_data_or_path)
        resources = template_hash['Resources'] || template_hash[:Resources] || {}

        upload_results.each do |res|
          apply_resource_s3_reference(resources, res)
        end

        if template_data_or_path.is_a?(String) && File.file?(template_data_or_path)
          sorted_template = deep_sort_keys(template_hash)
          File.write(template_data_or_path, YAML.dump(sorted_template))
        end

        template_hash
      end

      # 一括アップロードとテンプレート更新を一連の流れで実行します
      def upload_and_update_template(build_result)
        upload_results = upload_build_result(build_result)

        target = if build_result.respond_to?(:template_path) && File.file?(build_result.template_path.to_s)
                   build_result.template_path
                 elsif build_result.respond_to?(:template_data) && build_result.template_data.is_a?(Hash)
                   build_result.template_data
                 end

        updated_template = target ? update_template(target, upload_results: upload_results) : nil

        {
          upload_results: upload_results,
          template: updated_template
        }
      end

      private

      def client
        @client ||= resolve_s3_client
      end

      def resolve_s3_client
        return @s3_client if @s3_client

        begin
          require 'aws-sdk-s3' unless defined?(::Aws::S3::Client)
          ::Aws::S3::Client.new(region: resolve_region)
        rescue LoadError => e
          raise S3UploadError.new(
            "AWS SDK (aws-sdk-s3) is not available: #{e.message}. Please install aws-sdk-s3.",
            bucket: @bucket
          )
        rescue StandardError => e
          raise S3UploadError.new(
            "Failed to initialize AWS S3 client: #{e.message}",
            bucket: @bucket,
            original_error: e
          )
        end
      end

      def already_exists?(key)
        client.head_object(bucket: @bucket, key: key)
        true
      rescue StandardError => e
        if not_found_error?(e)
          false
        else
          raise_s3_error(e, key: key, operation: :head_object)
        end
      end

      def not_found_error?(error)
        error_class = error.class.name
        return true if error_class.include?('NotFound') || error_class.include?('NoSuchKey')

        if error.respond_to?(:context) && error.context.respond_to?(:http_response) &&
           error.context.http_response.status_code == 404
          return true
        end

        error.message.include?('404') || error.message.include?('NotFound') || error.message.include?('NoSuchKey')
      end

      def execute_put_object(file_path, key)
        File.open(file_path, 'rb') do |body|
          client.put_object(
            bucket: @bucket,
            key: key,
            body: body
          )
        end
      rescue StandardError => e
        raise_s3_error(e, key: key, operation: :put_object)
      end

      def apply_resource_s3_reference(resources, res)
        if res.type == :function
          logical_id = Compiler::LogicalId.for_function(res.name)
          res_entry = resources[logical_id] || resources[logical_id.to_sym]
          return unless res_entry

          props = res_entry['Properties'] ||= {}
          props['Code'] = { 'S3Bucket' => res.bucket, 'S3Key' => res.key }
        elsif res.type == :layer
          logical_id = Compiler::LogicalId.for_layer_version(res.name)
          res_entry = resources[logical_id] || resources[logical_id.to_sym]
          return unless res_entry

          props = res_entry['Properties'] ||= {}
          props['Content'] = { 'S3Bucket' => res.bucket, 'S3Key' => res.key }
        end
      end

      def load_template_hash(template_data_or_path)
        if template_data_or_path.is_a?(Hash)
          deep_dup(template_data_or_path)
        elsif File.file?(template_data_or_path.to_s)
          YAML.safe_load_file(template_data_or_path.to_s) || {}
        else
          raise ArgumentError, "Invalid template data or path: #{template_data_or_path.inspect}"
        end
      end

      def raise_s3_error(error, key:, operation:)
        error_name = error.class.name
        msg = error.message

        op_name = operation == :head_object ? 'HeadObject' : 'PutObject'
        user_message = if error_name.include?('NoSuchBucket') || msg.include?('NoSuchBucket')
                         "S3 bucket '#{@bucket}' does not exist. Please specify a valid bucket."
                       elsif error_name.include?('AccessDenied') || msg.include?('AccessDenied')
                         [
                           "Access denied to S3 bucket '#{@bucket}' (key: '#{key}').",
                           "Verify AWS permissions for s3:#{op_name}."
                         ].join(' ')
                       elsif error_name.include?('Credentials') || msg.include?('credentials')
                         "AWS credentials error while accessing S3: #{msg}. Please configure valid AWS credentials."
                       else
                         "Failed to #{operation} for S3 bucket '#{@bucket}' (key: '#{key}'): #{msg}"
                       end

        raise S3UploadError.new(user_message, bucket: @bucket, key: key, original_error: error)
      end

      def resolve_app_name
        if @application.respond_to?(:name) && !@application.name.to_s.strip.empty?
          @application.name.to_s.strip
        else
          'app'
        end
      end

      def resolve_stage_name
        if @application.respond_to?(:stage) && !@application.stage.to_s.strip.empty?
          @application.stage.to_s.strip
        else
          'dev'
        end
      end

      def resolve_region
        if @application.respond_to?(:region) && !@application.region.to_s.strip.empty?
          @application.region.to_s.strip
        else
          'ap-northeast-1'
        end
      end

      def deep_dup(obj)
        case obj
        when Hash
          obj.transform_values { |v| deep_dup(v) }
        when Array
          obj.map { |v| deep_dup(v) }
        else
          obj
        end
      end

      def deep_sort_keys(obj)
        case obj
        when Hash
          obj.keys.sort_by(&:to_s).to_h do |k|
            [k.to_s, deep_sort_keys(obj[k])]
          end
        when Array
          obj.map { |v| deep_sort_keys(v) }
        else
          obj
        end
      end
    end
  end
end
