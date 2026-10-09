# frozen_string_literal: true

require_relative '../compiler/logical_id'

module Veltrunode
  module AWS
    class LayerCleaner
      DEFAULT_CONFIRMATION_MSG =
        'Pruning layer versions in production requires explicit confirmation (--confirm or -y).'

      class ConfirmationRequiredError < Veltrunode::Error
        def initialize(message = DEFAULT_CONFIRMATION_MSG)
          super
        end
      end

      # クリーンアップ結果を保持する値オブジェクト
      class Report
        attr_reader :layer_name,
                    :retained_limit,
                    :dry_run,
                    :stage,
                    :versions,
                    :pruned_versions,
                    :retained_versions,
                    :referenced_versions,
                    :summary

        def initialize(
          layer_name:,
          retained_limit:,
          dry_run:,
          stage:,
          versions:,
          pruned_versions:,
          retained_versions:,
          referenced_versions:,
          summary:
        )
          @layer_name = layer_name.to_s.freeze
          @retained_limit = retained_limit.to_i
          @dry_run = dry_run ? true : false
          @stage = stage&.to_s&.freeze
          @versions = Array(versions).freeze
          @pruned_versions = Array(pruned_versions).freeze
          @retained_versions = Array(retained_versions).freeze
          @referenced_versions = Array(referenced_versions).freeze
          @summary = summary.freeze
          freeze
        end

        def dry_run?
          @dry_run
        end

        def to_h
          {
            'layer_name' => layer_name,
            'retained_limit' => retained_limit,
            'dry_run' => dry_run,
            'stage' => stage,
            'summary' => summary,
            'versions' => versions,
            'pruned_versions' => pruned_versions,
            'retained_versions' => retained_versions,
            'referenced_versions' => referenced_versions
          }
        end
      end

      class << self
        def prune(
          application:,
          layer_name:,
          aws_client: nil,
          retain_limit: nil,
          dry_run: false,
          confirm: false,
          prompt_in: $stdin,
          prompt_out: $stdout,
          functions_override: nil
        )
          new(
            application: application,
            layer_name: layer_name,
            aws_client: aws_client,
            retain_limit: retain_limit,
            dry_run: dry_run,
            confirm: confirm,
            prompt_in: prompt_in,
            prompt_out: prompt_out,
            functions_override: functions_override
          ).prune
        end
      end

      attr_reader :application,
                  :layer_name,
                  :aws_client,
                  :retain_limit,
                  :dry_run,
                  :confirm,
                  :prompt_in,
                  :prompt_out

      def initialize(
        application:,
        layer_name:,
        aws_client: nil,
        retain_limit: nil,
        dry_run: false,
        confirm: false,
        prompt_in: $stdin,
        prompt_out: $stdout,
        functions_override: nil
      )
        @application = application
        @layer_name = layer_name.to_s.strip
        @aws_client = aws_client
        @layer = find_layer
        @retain_limit = resolve_retain_limit(retain_limit)
        @dry_run = dry_run ? true : false
        @confirm = confirm ? true : false
        @prompt_in = prompt_in
        @prompt_out = prompt_out
        @functions_override = functions_override
      end

      def prune
        raise ArgumentError, "Layer '#{@layer_name}' not found in application" unless @layer

        # 本番環境での実行時は明示的な確認を要求
        ensure_production_confirmation! unless @dry_run

        published_versions = fetch_published_versions
        return empty_report if published_versions.empty?

        references_map = detect_references(published_versions)
        planned = plan_cleanup(published_versions, references_map)

        # dry-run でない場合は実際に削除を実行
        unless @dry_run
          planned[:to_prune].each do |item|
            delete_version_from_aws(item['version'])
            item['status'] = 'pruned'
          end
        end

        build_report(planned)
      end

      # クリーンアップ判定（外部から純粋に判定ロジックのみを呼び出し可能）
      def plan_cleanup(published_versions, references_map)
        # バージョン降順（最新順）にソート
        sorted = published_versions.sort_by { |v| -(v['version'] || v[:version]).to_i }

        all_items = []
        retained = []
        referenced = []
        to_prune = []

        sorted.each_with_index do |v, idx|
          ver_num = (v['version'] || v[:version]).to_i
          arn = (v['layer_version_arn'] || v[:layer_version_arn]).to_s
          created = (v['created_date'] || v[:created_date]).to_s
          desc = (v['description'] || v[:description]).to_s

          refs = Array(references_map[arn] || references_map[ver_num]).uniq.sort

          item = {
            'version' => ver_num,
            'layer_version_arn' => arn,
            'created_date' => created,
            'description' => desc,
            'references' => refs
          }

          if idx < @retain_limit
            # 最新 N 個のバージョンは無条件で保持
            item['status'] = 'retained_as_latest'
            retained << item
          elsif refs.any?
            # 最新 N 個より古くても、他リソースから参照されているバージョンは保護
            item['status'] = 'retained_as_referenced'
            referenced << item
            retained << item
          else
            # 古く、かつ参照されていないバージョンは削除対象
            item['status'] = @dry_run ? 'to_prune' : 'pruned'
            to_prune << item
          end

          all_items << item
        end

        {
          all: all_items,
          retained: retained,
          referenced: referenced,
          to_prune: to_prune
        }
      end

      private

      def find_layer
        return nil unless @application.respond_to?(:layers) && @application.layers

        @application.layers.find { |l| l.name == @layer_name }
      end

      def resolve_retain_limit(explicit_limit)
        return explicit_limit.to_i if explicit_limit&.to_i&.positive?

        if @layer.respond_to?(:retention_policy) && @layer.retention_policy.is_a?(Hash)
          pol_latest = @layer.retention_policy[:latest] || @layer.retention_policy['latest']
          return pol_latest.to_i if pol_latest&.to_i&.positive?
        end

        5 # デフォルト保持数
      end

      def production?
        stage = @application.respond_to?(:stage) ? @application.stage.to_s.downcase : ''
        %w[prod production].include?(stage)
      end

      def ensure_production_confirmation!
        return unless production?
        return if @confirm

        if @prompt_in && @prompt_out && @prompt_in.respond_to?(:tty?) && @prompt_in.tty?
          @prompt_out.print(
            "WARNING: You are about to prune layer versions in production ('#{@application.stage}'). Continue? [y/N]: "
          )
          response = @prompt_in.gets.to_s.strip
          return if response.match?(/\A(y|yes)\z/i)
        end

        raise ConfirmationRequiredError,
              "Pruning layer versions in production ('#{@application.stage}') " \
              'requires explicit confirmation (--confirm or -y).'
      end

      def fetch_published_versions
        client = resolve_aws_client
        return [] unless client

        layer_names_to_try = [
          "#{@application.name}-#{@layer.name}",
          @layer.name.to_s,
          Compiler::LogicalId.for_layer_version(@layer.name)
        ].uniq

        versions = []
        layer_names_to_try.each do |name|
          resp = client.list_layer_versions(layer_name: name)
          next if resp.layer_versions.nil? || resp.layer_versions.empty?

          resp.layer_versions.each do |v|
            versions << {
              'version' => v.version,
              'layer_version_arn' => v.layer_version_arn,
              'created_date' => v.created_date.to_s,
              'description' => v.description.to_s
            }
          end
          break unless versions.empty?
        rescue StandardError
          next
        end

        versions
      end

      def detect_references(published_versions)
        references_map = Hash.new { |h, k| h[k] = [] }
        known_arns = published_versions.map { |v| (v['layer_version_arn'] || v[:layer_version_arn]).to_s }

        # 1. functions_override が指定されている場合（テスト用など）
        if @functions_override
          scan_functions_for_layers(@functions_override, known_arns, references_map)
          return references_map
        end

        # 2. AWS から Lambda 関数一覧を取得して参照をスキャン
        client = resolve_aws_client
        if client
          begin
            paginator_resp = client.list_functions
            functions = paginator_resp.functions || []
            scan_functions_for_layers(functions, known_arns, references_map)
          rescue StandardError
            # AWS list_functions が失敗した場合でもローカル参照を確認
          end
        end

        # 3. ローカルの application.functions も確認
        if @application.respond_to?(:functions) && @application.functions
          @application.functions.each do |fn|
            fn_name = fn.respond_to?(:logical_name) ? fn.logical_name : fn.name
            attached = fn.respond_to?(:layers) ? Array(fn.layers) : []
            attached.each do |layer_ref|
              l_str = layer_ref.respond_to?(:name) ? layer_ref.name.to_s : layer_ref.to_s
              if l_str.start_with?('arn:') && known_arns.include?(l_str)
                references_map[l_str] << "local_function:#{fn_name}"
              end
            end
          end
        end

        references_map
      end

      def scan_functions_for_layers(functions, known_arns, references_map)
        functions.each do |fn|
          fn_name = fn.respond_to?(:function_name) ? fn.function_name : (fn['function_name'] || fn[:function_name])
          layers = fn.respond_to?(:layers) ? fn.layers : (fn['layers'] || fn[:layers])
          next unless layers

          layers.each do |layer_obj|
            arn = layer_obj.respond_to?(:arn) ? layer_obj.arn : (layer_obj['arn'] || layer_obj[:arn])
            next unless arn

            next unless known_arns.include?(arn.to_s)

            references_map[arn.to_s] << "function:#{fn_name}"
          end
        end
      end

      def delete_version_from_aws(version_number)
        client = resolve_aws_client
        return unless client

        layer_names_to_try = [
          "#{@application.name}-#{@layer.name}",
          @layer.name.to_s,
          Compiler::LogicalId.for_layer_version(@layer.name)
        ].uniq

        layer_names_to_try.each do |name|
          client.delete_layer_version(
            layer_name: name,
            version_number: version_number
          )
          break
        rescue StandardError
          next
        end
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

      def build_report(planned)
        summary = {
          'total_versions' => planned[:all].size,
          'retained_count' => planned[:retained].size,
          'referenced_count' => planned[:referenced].size,
          'pruned_count' => planned[:to_prune].size,
          'dry_run' => @dry_run
        }

        Report.new(
          layer_name: @layer.name,
          retained_limit: @retain_limit,
          dry_run: @dry_run,
          stage: @application.respond_to?(:stage) ? @application.stage : nil,
          versions: planned[:all],
          pruned_versions: planned[:to_prune],
          retained_versions: planned[:retained],
          referenced_versions: planned[:referenced],
          summary: summary
        )
      end

      def empty_report
        summary = {
          'total_versions' => 0,
          'retained_count' => 0,
          'referenced_count' => 0,
          'pruned_count' => 0,
          'dry_run' => @dry_run
        }

        Report.new(
          layer_name: @layer.name,
          retained_limit: @retain_limit,
          dry_run: @dry_run,
          stage: @application.respond_to?(:stage) ? @application.stage : nil,
          versions: [],
          pruned_versions: [],
          retained_versions: [],
          referenced_versions: [],
          summary: summary
        )
      end
    end
  end
end
