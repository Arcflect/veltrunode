# frozen_string_literal: true

require 'zip'
require_relative '../diagnostics'

module Veltrunode
  module Build
    # ビルド時に各パッケージ（Function / Layer）のサイズ診断、
    # 最も大きなエントリ（トップ10）、Layer間および関数-Layer間の重複ファイル、
    # 推奨される配置場所（関数 vs Layer vs EFS）、Lambda制限に対するパーセンテージ、
    # 制限超過時の警告出力を担当するクラス
    class SizeDiagnostics
      LAMBDA_COMPRESSED_LIMIT_BYTES = 50 * 1024 * 1024 # 50 MB
      LAMBDA_UNCOMPRESSED_LIMIT_BYTES = 250 * 1024 * 1024 # 250 MB
      RECOMMENDED_FUNCTION_MAX_BYTES = 10 * 1024 * 1024 # 10 MB
      LARGE_ENTRY_THRESHOLD_BYTES = 20 * 1024 * 1024 # 20 MB

      # 個別アーティファクト（Function または Layer の ZIP）のサイズレポート
      class ArtifactReport
        attr_reader :name,
                    :type,
                    :zip_path,
                    :compressed_size,
                    :uncompressed_size,
                    :total_entries,
                    :largest_entries,
                    :entries_map,
                    :placement_recommendation

        def initialize(
          name:,
          type:,
          zip_path:,
          compressed_size:,
          uncompressed_size:,
          total_entries:,
          largest_entries:,
          entries_map: {},
          placement_recommendation: nil
        )
          @name = name.to_s.freeze
          @type = type.to_sym
          @zip_path = zip_path.to_s.freeze
          @compressed_size = compressed_size.to_i
          @uncompressed_size = uncompressed_size.to_i
          @total_entries = total_entries.to_i
          @largest_entries = Array(largest_entries).freeze
          @entries_map = (entries_map || {}).freeze
          @placement_recommendation = placement_recommendation
          freeze
        end

        def compressed_percentage
          return 0.0 unless LAMBDA_COMPRESSED_LIMIT_BYTES.positive?

          ((compressed_size.to_f / LAMBDA_COMPRESSED_LIMIT_BYTES) * 100).round(1)
        end

        def uncompressed_percentage
          return 0.0 unless LAMBDA_UNCOMPRESSED_LIMIT_BYTES.positive?

          ((uncompressed_size.to_f / LAMBDA_UNCOMPRESSED_LIMIT_BYTES) * 100).round(1)
        end

        def compressed_exceeded?
          compressed_size > LAMBDA_COMPRESSED_LIMIT_BYTES
        end

        def uncompressed_exceeded?
          uncompressed_size > LAMBDA_UNCOMPRESSED_LIMIT_BYTES
        end

        def exceeded?
          compressed_exceeded? || uncompressed_exceeded?
        end

        def function?
          @type == :function
        end

        def layer?
          @type == :layer
        end

        def to_h
          {
            'name' => name,
            'type' => type.to_s,
            'zip_path' => zip_path,
            'size' => {
              'compressed_bytes' => compressed_size,
              'uncompressed_bytes' => uncompressed_size,
              'compressed_limit_bytes' => LAMBDA_COMPRESSED_LIMIT_BYTES,
              'uncompressed_limit_bytes' => LAMBDA_UNCOMPRESSED_LIMIT_BYTES,
              'compressed_percentage' => compressed_percentage,
              'uncompressed_percentage' => uncompressed_percentage,
              'compressed_exceeded' => compressed_exceeded?,
              'uncompressed_exceeded' => uncompressed_exceeded?
            },
            'total_entries' => total_entries,
            'largest_entries' => largest_entries,
            'placement_recommendation' => placement_recommendation
          }
        end
      end

      # ビルド全体のサイズ診断レポート
      class Report
        attr_reader :artifacts,
                    :largest_entries,
                    :layer_duplicates,
                    :function_layer_duplicates,
                    :placement_recommendations,
                    :diagnostics

        def initialize(
          artifacts:,
          largest_entries:,
          layer_duplicates:,
          function_layer_duplicates:,
          placement_recommendations:,
          diagnostics: []
        )
          @artifacts = Array(artifacts).freeze
          @largest_entries = Array(largest_entries).freeze
          @layer_duplicates = Array(layer_duplicates).freeze
          @function_layer_duplicates = Array(function_layer_duplicates).freeze
          @placement_recommendations = Array(placement_recommendations).freeze
          @diagnostics = Array(diagnostics).freeze
          freeze
        end

        def functions
          @artifacts.select(&:function?)
        end

        def layers
          @artifacts.select(&:layer?)
        end

        def exceeded?
          @artifacts.any?(&:exceeded?)
        end

        def to_h
          {
            'artifacts' => @artifacts.map(&:to_h),
            'top_largest_entries' => @largest_entries,
            'duplicates' => {
              'layer_duplicates' => @layer_duplicates,
              'function_layer_duplicates' => @function_layer_duplicates
            },
            'placement_recommendations' => @placement_recommendations,
            'diagnostics' => @diagnostics.map(&:to_h)
          }
        end

        def to_text
          lines = ['Package Size Diagnostics:']

          append_artifacts_text(lines, 'Layers', layers) unless layers.empty?
          append_artifacts_text(lines, 'Functions', functions) unless functions.empty?

          append_duplicates_text(lines)
          append_recommendations_text(lines)
          append_warnings_text(lines)

          lines.join("\n")
        end

        private

        def append_artifacts_text(lines, header, items)
          lines << "  #{header}:"
          items.each do |item|
            comp_mb = SizeDiagnostics.format_bytes(item.compressed_size)
            uncomp_mb = SizeDiagnostics.format_bytes(item.uncompressed_size)
            status_flags = []
            status_flags << 'COMPRESSED LIMIT EXCEEDED' if item.compressed_exceeded?
            status_flags << 'UNCOMPRESSED LIMIT EXCEEDED' if item.uncompressed_exceeded?
            status_suffix = status_flags.empty? ? '' : " [! #{status_flags.join(', ')}]"

            lines << "    - #{item.name}: #{comp_mb} / 50.0 MB (#{item.compressed_percentage}%) compressed, " \
                     "#{uncomp_mb} / 250.0 MB (#{item.uncompressed_percentage}%) uncompressed#{status_suffix}"

            next if item.largest_entries.empty?

            lines << '      Top entries:'
            item.largest_entries.first(5).each_with_index do |entry, idx|
              lines << "        #{idx + 1}. #{entry['path']} (#{SizeDiagnostics.format_bytes(entry['size'])}, " \
                       "#{entry['percentage']}%)"
            end
          end
        end

        def append_duplicates_text(lines)
          has_layer_dups = !layer_duplicates.empty?
          has_fn_dups = !function_layer_duplicates.empty?
          return unless has_layer_dups || has_fn_dups

          lines << '  Duplicate Files:'
          if has_layer_dups
            lines << '    Between Layers:'
            layer_duplicates.each do |dup|
              layers_str = dup['layers'].join(', ')
              lines << "      - #{dup['path']} (#{SizeDiagnostics.format_bytes(dup['size'])}) in [#{layers_str}]"
            end
          end

          return unless has_fn_dups

          lines << '    Between Functions and Layers:'
          function_layer_duplicates.each do |dup|
            lines << "      - #{dup['path']} (#{SizeDiagnostics.format_bytes(dup['size'])}) in function " \
                     "'#{dup['function']}' and layer '#{dup['layer']}'"
          end
        end

        def append_recommendations_text(lines)
          return if placement_recommendations.empty?

          lines << '  Placement Recommendations:'
          placement_recommendations.each do |rec|
            lines << "    - [#{rec['target']}] #{rec['resource']}: #{rec['recommendation']}"
          end
        end

        def append_warnings_text(lines)
          warnings = diagnostics.select { |d| %i[warning error].include?(d.severity) }
          return if warnings.empty?

          lines << '  Warnings:'
          warnings.each do |w|
            lines << "    - [#{w.code}] #{w.summary}"
          end
        end
      end

      class << self
        def analyze(application, function_results: [], layer_results: [], source_dir: Dir.pwd)
          new(
            application: application,
            function_results: function_results,
            layer_results: layer_results,
            source_dir: source_dir
          ).analyze
        end

        def format_bytes(bytes)
          b = bytes.to_f
          if b >= 1024 * 1024 * 1024
            "#{(b / (1024 * 1024 * 1024)).round(1)} GB"
          elsif b >= 1024 * 1024
            "#{(b / (1024 * 1024)).round(1)} MB"
          elsif b >= 1024
            "#{(b / 1024).round(1)} KB"
          else
            "#{bytes.to_i} B"
          end
        end
      end

      def initialize(application:, function_results: [], layer_results: [], source_dir: Dir.pwd)
        @application = application
        @function_results = Array(function_results)
        @layer_results = Array(layer_results)
        @source_dir = File.expand_path(source_dir.to_s)
        @diagnostics = []
      end

      def analyze
        # 1. 各ZIPアーティファクトの個別解析
        layer_reports = analyze_layers
        function_reports = analyze_functions
        all_artifacts = layer_reports + function_reports

        # 2. 全体でのトップ10エントリ抽出
        overall_top_entries = extract_overall_largest_entries(all_artifacts)

        # 3. Layer間の重複ファイル検出
        layer_duplicates = detect_layer_duplicates(layer_reports)

        # 4. 関数とLayer間の重複ファイル検出
        fn_layer_duplicates = detect_function_layer_duplicates(function_reports, layer_reports)

        # 5. 配置推奨の判定（Function vs Layer vs EFS）
        placement_recommendations = determine_placement_recommendations(
          all_artifacts,
          layer_duplicates,
          fn_layer_duplicates
        )

        # 6. Lambdaサイズ制限超過時の警告（Diagnostic）生成
        generate_size_limit_diagnostics(all_artifacts)

        Report.new(
          artifacts: all_artifacts,
          largest_entries: overall_top_entries,
          layer_duplicates: layer_duplicates,
          function_layer_duplicates: fn_layer_duplicates,
          placement_recommendations: placement_recommendations,
          diagnostics: @diagnostics
        )
      end

      private

      def analyze_layers
        @layer_results.map do |res|
          layer_name = res.respond_to?(:layer_name) ? res.layer_name : res.to_s
          zip_path = res.respond_to?(:zip_path) ? res.zip_path : nil
          zip_path ||= File.join(@source_dir, 'build', 'artifacts', 'layers', "#{layer_name}.zip")

          inspect_artifact(name: layer_name, type: :layer, zip_path: zip_path)
        end
      end

      def analyze_functions
        @function_results.map do |res|
          fn_name = res.respond_to?(:function_name) ? res.function_name : res.to_s
          zip_path = res.respond_to?(:zip_path) ? res.zip_path : nil
          zip_path ||= File.join(@source_dir, 'build', 'artifacts', 'functions', "#{fn_name}.zip")

          inspect_artifact(name: fn_name, type: :function, zip_path: zip_path)
        end
      end

      def inspect_artifact(name:, type:, zip_path:)
        unless zip_path && File.file?(zip_path)
          return ArtifactReport.new(
            name: name,
            type: type,
            zip_path: zip_path.to_s,
            compressed_size: 0,
            uncompressed_size: 0,
            total_entries: 0,
            largest_entries: [],
            entries_map: {},
            placement_recommendation: nil
          )
        end

        compressed_size = File.size(zip_path)
        uncompressed_size = 0
        total_entries = 0
        entries = []
        entries_map = {}

        Zip::File.open(zip_path) do |zip|
          total_entries = zip.size
          zip.each do |entry|
            next if entry.directory?

            uncompressed_size += entry.size
            entries << { 'path' => entry.name, 'size' => entry.size }
            entries_map[entry.name] = entry.size
          end
        end

        largest_entries = entries.sort_by { |e| -e['size'] }.first(10).map do |e|
          pct = uncompressed_size.positive? ? ((e['size'].to_f / uncompressed_size) * 100).round(1) : 0.0
          {
            'path' => e['path'],
            'size' => e['size'],
            'percentage' => pct
          }
        end

        recommendation = evaluate_artifact_placement(
          type: type,
          compressed_size: compressed_size,
          uncompressed_size: uncompressed_size,
          largest_entries: largest_entries
        )

        ArtifactReport.new(
          name: name,
          type: type,
          zip_path: zip_path,
          compressed_size: compressed_size,
          uncompressed_size: uncompressed_size,
          total_entries: total_entries,
          largest_entries: largest_entries,
          entries_map: entries_map,
          placement_recommendation: recommendation
        )
      end

      def extract_overall_largest_entries(artifacts)
        all_entries = []
        artifacts.each do |art|
          art.entries_map.each do |path, size|
            pct = art.uncompressed_size.positive? ? ((size.to_f / art.uncompressed_size) * 100).round(1) : 0.0
            all_entries << {
              'path' => path,
              'size' => size,
              'percentage' => pct,
              'artifact_name' => art.name,
              'artifact_type' => art.type.to_s
            }
          end
        end

        all_entries.sort_by { |e| -e['size'] }.first(10)
      end

      def detect_layer_duplicates(layer_reports)
        duplicates = []
        return duplicates if layer_reports.size < 2

        seen_paths = {}
        layer_reports.each do |layer|
          layer.entries_map.each do |path, size|
            norm = normalize_path(path)
            seen_paths[norm] ||= { 'path' => path, 'size' => size, 'layers' => [] }
            seen_paths[norm]['layers'] << layer.name
          end
        end

        seen_paths.each_value do |info|
          layers = info['layers'].uniq
          next unless layers.size > 1

          duplicates << {
            'path' => info['path'],
            'size' => info['size'],
            'layers' => layers,
            'recommendation' => "File is present in multiple layers (#{layers.join(', ')}). " \
                                'Consolidate into a single shared layer.'
          }
        end

        duplicates
      end

      def detect_function_layer_duplicates(function_reports, layer_reports)
        duplicates = []
        return duplicates if function_reports.empty? || layer_reports.empty?

        function_reports.each do |fn|
          fn.entries_map.each do |fn_path, fn_size|
            norm_fn = normalize_path(fn_path)

            layer_reports.each do |layer|
              # Layer内のエントリと比較
              matching_layer_path = layer.entries_map.keys.find do |layer_path|
                normalize_path(layer_path) == norm_fn
              end

              next unless matching_layer_path

              duplicates << {
                'path' => fn_path,
                'size' => fn_size,
                'function' => fn.name,
                'layer' => layer.name,
                'recommendation' => "Exclude '#{fn_path}' from function '#{fn.name}' bundle " \
                                    "as it is already provided by layer '#{layer.name}'."
              }
            end
          end
        end

        duplicates
      end

      def determine_placement_recommendations(artifacts, layer_duplicates, fn_layer_duplicates)
        recs = []

        # アーティファクト単位の推奨
        artifacts.each do |art|
          if art.uncompressed_exceeded?
            recs << {
              'resource' => art.name,
              'type' => art.type.to_s,
              'target' => 'EFS',
              'recommendation' => "Uncompressed size (#{SizeDiagnostics.format_bytes(art.uncompressed_size)}) " \
                                  'exceeds Lambda limit (250 MB). Move heavy dependencies or datasets to EFS.'
            }
          elsif art.compressed_exceeded?
            recs << {
              'resource' => art.name,
              'type' => art.type.to_s,
              'target' => 'EFS',
              'recommendation' => "Compressed size (#{SizeDiagnostics.format_bytes(art.compressed_size)}) " \
                                  'exceeds Lambda limit (50 MB). Move assets or dependencies to EFS.'
            }
          elsif art.function? && art.uncompressed_size > RECOMMENDED_FUNCTION_MAX_BYTES
            recs << {
              'resource' => art.name,
              'type' => 'function',
              'target' => 'Layer',
              'recommendation' => "Function package size (#{SizeDiagnostics.format_bytes(art.uncompressed_size)}) " \
                                  'is relatively large (> 10 MB). Move dependencies to a Lambda Layer.'
            }
          elsif art.function?
            recs << {
              'resource' => art.name,
              'type' => 'function',
              'target' => 'Function',
              'recommendation' => 'Lightweight package is well-suited for direct deployment in Function bundle.'
            }
          elsif art.layer?
            recs << {
              'resource' => art.name,
              'type' => 'layer',
              'target' => 'Layer',
              'recommendation' => 'Shared dependencies appropriately placed in Lambda Layer.'
            }
          end

          # 単一巨大エントリに対するEFS推奨
          art.largest_entries.each do |entry|
            next unless entry['size'] >= LARGE_ENTRY_THRESHOLD_BYTES

            recs << {
              'resource' => "#{art.name}:#{entry['path']}",
              'type' => 'entry',
              'target' => 'EFS',
              'recommendation' => "Large file '#{entry['path']}' (#{SizeDiagnostics.format_bytes(entry['size'])}) " \
                                  'should be stored in EFS rather than bundled into Lambda package.'
            }
          end
        end

        # 重複ファイルに対する推奨
        layer_duplicates.each do |dup|
          recs << {
            'resource' => dup['path'],
            'type' => 'duplicate',
            'target' => 'Layer',
            'recommendation' => "Duplicated across layers [#{dup['layers'].join(', ')}]. " \
                                'Consolidate into a single shared layer.'
          }
        end

        fn_layer_duplicates.each do |dup|
          recs << {
            'resource' => "#{dup['function']}:#{dup['path']}",
            'type' => 'duplicate',
            'target' => 'Layer',
            'recommendation' => "Duplicated between function '#{dup['function']}' and layer '#{dup['layer']}'. " \
                                "Exclude from function and rely on layer '#{dup['layer']}'."
          }
        end

        recs
      end

      def evaluate_artifact_placement(type:, compressed_size:, uncompressed_size:, largest_entries:)
        if uncompressed_size > LAMBDA_UNCOMPRESSED_LIMIT_BYTES || compressed_size > LAMBDA_COMPRESSED_LIMIT_BYTES
          {
            'target' => 'EFS',
            'reason' => 'Exceeds AWS Lambda package size limit (50 MB compressed / 250 MB uncompressed).'
          }
        elsif largest_entries.any? { |e| e['size'] >= LARGE_ENTRY_THRESHOLD_BYTES }
          {
            'target' => 'EFS',
            'reason' => 'Contains large entry (>= 20 MB). Moving large assets to EFS is recommended.'
          }
        elsif type == :function && uncompressed_size > RECOMMENDED_FUNCTION_MAX_BYTES
          {
            'target' => 'Layer',
            'reason' => 'Function package is larger than 10 MB. Moving dependencies to a Layer is recommended.'
          }
        elsif type == :layer
          {
            'target' => 'Layer',
            'reason' => 'Shared dependency package is well-suited for Lambda Layer.'
          }
        else
          {
            'target' => 'Function',
            'reason' => 'Lightweight package is optimal for Function deployment.'
          }
        end
      end

      def generate_size_limit_diagnostics(artifacts)
        artifacts.each do |art|
          if art.uncompressed_exceeded?
            @diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-BUILD-SIZE-LIMIT',
              severity: :warning,
              summary: "Package '#{art.name}' uncompressed size " \
                       "(#{SizeDiagnostics.format_bytes(art.uncompressed_size)}) " \
                       "exceeds AWS Lambda limit of 250 MB (#{art.uncompressed_percentage}%).",
              suggested_action: 'Move large dependencies or data files to EFS or split into Lambda Layers.',
              evidence: {
                'artifact_name' => art.name,
                'artifact_type' => art.type.to_s,
                'uncompressed_bytes' => art.uncompressed_size,
                'uncompressed_limit_bytes' => LAMBDA_UNCOMPRESSED_LIMIT_BYTES,
                'percentage' => art.uncompressed_percentage
              }
            )
          end

          next unless art.compressed_exceeded?

          @diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-SIZE-LIMIT',
            severity: :warning,
            summary: "Package '#{art.name}' compressed size (#{SizeDiagnostics.format_bytes(art.compressed_size)}) " \
                     "exceeds AWS Lambda limit of 50 MB (#{art.compressed_percentage}%).",
            suggested_action: 'Reduce package contents or move large assets to EFS.',
            evidence: {
              'artifact_name' => art.name,
              'artifact_type' => art.type.to_s,
              'compressed_bytes' => art.compressed_size,
              'compressed_limit_bytes' => LAMBDA_COMPRESSED_LIMIT_BYTES,
              'percentage' => art.compressed_percentage
            }
          )
        end
      end

      def normalize_path(path)
        p = path.to_s
        p = p.sub(%r{^(?:ruby/gems/\d+\.\d+\.\d+/gems|vendor/bundle/ruby/\d+\.\d+\.\d+/gems)/}, '')
        p = p.sub(%r{^(?:python/lib/python\d+\.\d+/site-packages|site-packages|vendor/python)/}, '')
        p.sub(%r{^(?:nodejs/node_modules|node_modules)/}, '')
      end
    end
  end
end
