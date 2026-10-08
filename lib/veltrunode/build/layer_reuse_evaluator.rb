# frozen_string_literal: true

require 'json'
require_relative 'layer_packager'
require_relative '../compiler/logical_id'

module Veltrunode
  module Build
    # Layer のコンテンツハッシュに基づく既存バージョン再利用判定クラス
    # 不確実な推測を避け、検証不能な場合は安全に新規発行とする
    class LayerReuseEvaluator
      class Decision
        attr_reader :layer_name,
                    :content_hash,
                    :layer_version_arn,
                    :version,
                    :source,
                    :reason

        def initialize(
          reusable:,
          layer_name:,
          content_hash:,
          layer_version_arn: nil,
          version: nil,
          source: :none,
          reason: ''
        )
          @reusable = reusable ? true : false
          @layer_name = layer_name.to_s.freeze
          @content_hash = content_hash&.to_s&.freeze
          @layer_version_arn = layer_version_arn&.to_s&.freeze
          @version = version
          @source = source.to_sym
          @reason = reason.to_s.freeze
          freeze
        end

        def reusable?
          @reusable
        end

        def to_h
          {
            'reusable' => reusable?,
            'layer_name' => layer_name,
            'content_hash' => content_hash,
            'layer_version_arn' => layer_version_arn,
            'version' => version,
            'source' => source.to_s,
            'reason' => reason
          }
        end
      end

      class << self
        def evaluate(
          layer,
          application: nil,
          source_dir: Dir.pwd,
          manifest_path: nil,
          aws_client: nil,
          check_aws: true,
          check_manifest: true,
          content_hash: nil
        )
          new(
            layer: layer,
            application: application,
            source_dir: source_dir,
            manifest_path: manifest_path,
            aws_client: aws_client,
            check_aws: check_aws,
            check_manifest: check_manifest,
            content_hash: content_hash
          ).evaluate
        end
      end

      attr_reader :layer, :application, :source_dir, :manifest_path, :aws_client, :check_aws, :check_manifest

      def initialize(
        layer:,
        application: nil,
        source_dir: Dir.pwd,
        manifest_path: nil,
        aws_client: nil,
        check_aws: true,
        check_manifest: true,
        content_hash: nil
      )
        @layer = layer
        @application = application
        @source_dir = File.expand_path(source_dir.to_s.empty? ? Dir.pwd : source_dir.to_s)
        @manifest_path = if manifest_path
                           File.expand_path(manifest_path.to_s)
                         else
                           File.join(@source_dir, 'build', 'manifest.json')
                         end
        @aws_client = aws_client
        @check_aws = check_aws ? true : false
        @check_manifest = check_manifest ? true : false
        @explicit_content_hash = content_hash
      end

      def evaluate
        layer_name = extract_layer_name

        # 1. ビルド前にコンテンツハッシュを計算
        content_hash = calculate_content_hash
        unless content_hash
          return Decision.new(
            reusable: false,
            layer_name: layer_name,
            content_hash: nil,
            source: :none,
            reason: 'Failed to calculate layer content hash. Publishing new version.'
          )
        end

        # 2. マニフェストからハッシュ値・既存ARNを取得して照合
        if @check_manifest
          manifest_decision = evaluate_from_manifest(layer_name, content_hash)
          return manifest_decision if manifest_decision&.reusable?
        end

        # 3. AWS 上の Layer の Description メタデータからハッシュ値を取得して照合
        if @check_aws
          aws_decision = evaluate_from_aws(layer_name, content_hash)
          return aws_decision if aws_decision&.reusable?
        end

        # 4. 一致しないまたは検証不可能な場合は新規発行（不確実な推測を避ける）
        short_hash = content_hash[0..11]
        Decision.new(
          reusable: false,
          layer_name: layer_name,
          content_hash: content_hash,
          source: :none,
          reason: "No matching layer version found for hash '#{short_hash}'. Publishing new version."
        )
      rescue StandardError => e
        # 例外時も「不確実な推測を避け、新しいバージョンを発行」の原則に従う
        Decision.new(
          reusable: false,
          layer_name: extract_layer_name,
          content_hash: @explicit_content_hash,
          source: :none,
          reason: "Layer reuse evaluation error: #{e.message}. Publishing new version."
        )
      end

      private

      def extract_layer_name
        if @layer.respond_to?(:name)
          @layer.name.to_s
        elsif @layer.is_a?(Hash)
          (@layer[:name] || @layer['name']).to_s
        else
          @layer.to_s
        end
      end

      def calculate_content_hash
        return @explicit_content_hash.to_s if @explicit_content_hash

        if @layer.respond_to?(:content_hash) && @layer.content_hash && !@layer.content_hash.empty?
          return @layer.content_hash.to_s
        end

        LayerPackager.calculate_hash(
          layer: @layer,
          source_dir: @source_dir,
          skip_container_build: true
        )
      rescue StandardError
        nil
      end

      def evaluate_from_manifest(layer_name, content_hash)
        return nil unless File.file?(@manifest_path)

        manifest_data = JSON.parse(File.read(@manifest_path))
        layers_section = manifest_data['layers']
        return nil unless layers_section.is_a?(Hash)

        layer_entry = layers_section[layer_name] || layers_section[layer_name.to_sym]
        return nil unless layer_entry.is_a?(Hash)

        manifest_hash = layer_entry['content_hash'] || layer_entry['sha256'] || layer_entry['artifact_hash']
        arn = layer_entry['layer_version_arn'] || layer_entry['arn']

        return nil unless manifest_hash && manifest_hash.to_s == content_hash && valid_arn?(arn)

        short_hash = content_hash[0..11]
        Decision.new(
          reusable: true,
          layer_name: layer_name,
          content_hash: content_hash,
          layer_version_arn: arn.to_s,
          source: :manifest,
          reason: "Matching content hash '#{short_hash}' found in manifest (#{@manifest_path})."
        )
      rescue StandardError
        # マニフェスト読み込みやパース失敗時は検証不能のため nil を返して次の判定または新規発行へ
        nil
      end

      def evaluate_from_aws(layer_name, content_hash)
        client = resolve_aws_client
        return nil unless client

        layer_names_to_try = [
          @application ? "#{@application.name}-#{layer_name}" : nil,
          layer_name,
          Compiler::LogicalId.for_layer_version(layer_name)
        ].compact.uniq

        layer_names_to_try.each do |candidate_name|
          resp = client.list_layer_versions(layer_name: candidate_name)
          versions = resp.layer_versions
          next if versions.nil? || versions.empty?

          # 最新バージョンから順に照合
          sorted_versions = versions.sort_by do |v|
            ver = v.respond_to?(:version) ? v.version : v['version']
            -(ver || 0)
          end

          matched = sorted_versions.find do |v|
            desc = v.respond_to?(:description) ? v.description : v['description']
            description_matches_hash?(desc, content_hash)
          end

          if matched
            arn = matched.respond_to?(:layer_version_arn) ? matched.layer_version_arn : matched['layer_version_arn']
            ver = matched.respond_to?(:version) ? matched.version : matched['version']
            if valid_arn?(arn)
              short_hash = content_hash[0..11]
              return Decision.new(
                reusable: true,
                layer_name: layer_name,
                content_hash: content_hash,
                layer_version_arn: arn,
                version: ver,
                source: :aws_description,
                reason: "Matching content hash '#{short_hash}' found in AWS layer version #{ver} description."
              )
            end
          end
        rescue StandardError
          # AWS未認証、Layer不在、ネットワークエラー等は推測を避けて次の候補を試す
          next
        end

        nil
      end

      def description_matches_hash?(description, target_hash)
        return false if description.nil? || target_hash.nil?

        desc = description.to_s
        return true if desc.include?(target_hash)
        return true if desc.include?("hash:#{target_hash}")

        # hash:<hash_hex> 形式のメタデータ抽出
        if (m = desc.match(/(?:hash:|hash=|\bhash:?)([a-f0-9]{16,64})/i))
          extracted = m[1].downcase
          return true if target_hash.downcase.start_with?(extracted) || extracted.start_with?(target_hash.downcase)
        end

        false
      end

      def valid_arn?(arn)
        return false if arn.nil?

        str = arn.to_s.strip
        str.start_with?('arn:aws:lambda:') && str.include?(':layer:')
      end

      def resolve_aws_client
        return @aws_client if @aws_client

        begin
          require 'aws-sdk-lambda'
          region = @application.respond_to?(:region) ? @application.region : nil
          region ||= ENV['AWS_REGION'] || 'us-east-1'
          Aws::Lambda::Client.new(region: region)
        rescue LoadError, StandardError
          nil
        end
      end
    end
  end
end
