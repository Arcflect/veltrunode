# frozen_string_literal: true

require 'digest'
require 'zip'
require_relative '../../build/layer_packager'
require_relative '../../build/deterministic_archiver'
require_relative '../../compiler/logical_id'
require_relative '../../diagnostics'

module Veltrunode
  module AWS
    module Inspectors
      # Layer の状態検査、サイズ診断、再利用判定、発行履歴および重複ファイル検出を行うクラス
      class LayerInspector
        # 検査結果を保持する値オブジェクト
        class Report
          attr_reader :layer_name,
                      :description,
                      :compatible_runtimes,
                      :architectures,
                      :content_hash,
                      :sha256,
                      :zip_path,
                      :compressed_size,
                      :uncompressed_size,
                      :total_entries,
                      :largest_entries,
                      :published_versions,
                      :reusable,
                      :matched_version,
                      :matched_arn,
                      :reuse_reason,
                      :duplicate_files,
                      :diagnostics

          def initialize(
            layer_name:,
            description:,
            compatible_runtimes:,
            architectures:,
            content_hash:,
            sha256:,
            zip_path:,
            compressed_size:,
            uncompressed_size:,
            total_entries:,
            largest_entries:,
            published_versions:,
            reusable:,
            matched_version:,
            matched_arn:,
            reuse_reason:,
            duplicate_files:,
            diagnostics: []
          )
            @layer_name = layer_name.to_s.freeze
            @description = description&.to_s&.freeze
            @compatible_runtimes = Array(compatible_runtimes).map(&:to_s).freeze
            @architectures = Array(architectures).map(&:to_s).freeze
            @content_hash = content_hash.to_s.freeze
            @sha256 = sha256.to_s.freeze
            @zip_path = zip_path.to_s.freeze
            @compressed_size = compressed_size.to_i
            @uncompressed_size = uncompressed_size.to_i
            @total_entries = total_entries.to_i
            @largest_entries = Array(largest_entries).freeze
            @published_versions = Array(published_versions).freeze
            @reusable = reusable ? true : false
            @matched_version = matched_version
            @matched_arn = matched_arn&.to_s
            @reuse_reason = reuse_reason.to_s.freeze
            @duplicate_files = Array(duplicate_files).freeze
            @diagnostics = Array(diagnostics).freeze
            freeze
          end

          def reusable?
            @reusable
          end

          def to_h
            {
              'layer_name' => layer_name,
              'description' => description,
              'compatible_runtimes' => compatible_runtimes,
              'architectures' => architectures,
              'content_hash' => content_hash,
              'sha256' => sha256,
              'zip_path' => zip_path,
              'size' => {
                'compressed_bytes' => compressed_size,
                'uncompressed_bytes' => uncompressed_size,
                'total_entries' => total_entries
              },
              'reuse' => {
                'reusable' => reusable,
                'matched_version' => matched_version,
                'matched_arn' => matched_arn,
                'reason' => reuse_reason
              },
              'published_versions' => published_versions,
              'largest_entries' => largest_entries,
              'duplicate_files' => duplicate_files
            }
          end
        end

        class << self
          def inspect(application, layer_name:, source_dir: Dir.pwd, aws_client: nil, fetch_remote: true)
            new(
              application: application,
              layer_name: layer_name,
              source_dir: source_dir,
              aws_client: aws_client,
              fetch_remote: fetch_remote
            ).inspect
          end
        end

        def initialize(application:, layer_name:, source_dir: Dir.pwd, aws_client: nil, fetch_remote: true)
          @application = application
          @layer_name = layer_name.to_s.strip
          @source_dir = File.expand_path(source_dir.to_s)
          @aws_client = aws_client
          @fetch_remote = fetch_remote
          @diagnostics = []
        end

        def inspect
          layer = find_layer
          raise ArgumentError, "Layer '#{@layer_name}' not found in application '#{@application.name}'" unless layer

          pkg_result = resolve_or_package_layer(layer)
          size_info = inspect_zip_size_and_entries(pkg_result.zip_path)
          duplicates = detect_duplicate_files(layer, pkg_result)
          published_versions = @fetch_remote ? fetch_published_versions(layer) : []
          reuse_info = evaluate_reuse(pkg_result.content_hash, published_versions)

          Report.new(
            layer_name: layer.name,
            description: layer.description,
            compatible_runtimes: layer.compatible_runtimes,
            architectures: layer.architectures,
            content_hash: pkg_result.content_hash,
            sha256: pkg_result.sha256,
            zip_path: pkg_result.zip_path,
            compressed_size: size_info[:compressed_size],
            uncompressed_size: size_info[:uncompressed_size],
            total_entries: size_info[:total_entries],
            largest_entries: size_info[:largest_entries],
            published_versions: published_versions,
            reusable: reuse_info[:reusable],
            matched_version: reuse_info[:matched_version],
            matched_arn: reuse_info[:matched_arn],
            reuse_reason: reuse_info[:reason],
            duplicate_files: duplicates,
            diagnostics: @diagnostics
          )
        end

        private

        def find_layer
          @application.layers.find { |l| l.name == @layer_name }
        end

        ResolvedArtifact = Struct.new(:zip_path, :content_hash, :sha256)
        private_constant :ResolvedArtifact

        def resolve_or_package_layer(layer)
          default_zip = File.join(@source_dir, 'build', 'artifacts', 'layers', "#{layer.name}.zip")
          if File.exist?(default_zip)
            sha256 = Digest::SHA256.file(default_zip).hexdigest
            content_hash = layer.content_hash || sha256
            return ResolvedArtifact.new(
              default_zip,
              content_hash,
              sha256
            )
          end

          output_dir = File.join(@source_dir, 'build', 'artifacts', 'layers')
          Build::LayerPackager.package(
            layer: layer,
            source_dir: @source_dir,
            output_dir: output_dir,
            no_cache: false
          )
        end

        def inspect_zip_size_and_entries(zip_path)
          uncompressed_size = 0
          entry_count = 0
          entries = []

          Zip::File.open(zip_path) do |zip|
            entry_count = zip.size
            zip.each do |entry|
              next if entry.directory?

              uncompressed_size += entry.size
              entries << { 'path' => entry.name, 'size' => entry.size }
            end
          end

          largest_entries = entries.sort_by { |e| -e['size'] }.first(5).map do |e|
            pct = uncompressed_size.positive? ? ((e['size'].to_f / uncompressed_size) * 100).round(1) : 0.0
            {
              'path' => e['path'],
              'size' => e['size'],
              'percentage' => pct
            }
          end

          {
            compressed_size: File.exist?(zip_path) ? File.size(zip_path) : 0,
            uncompressed_size: uncompressed_size,
            total_entries: entry_count,
            largest_entries: largest_entries
          }
        end

        def detect_duplicate_files(layer, pkg_result)
          layer_entries = extract_zip_entries(pkg_result.zip_path)
          duplicates = []

          detect_duplicates_across_other_layers(layer, layer_entries, duplicates)
          detect_duplicates_across_functions(layer, layer_entries, duplicates)

          duplicates
        end

        def extract_zip_entries(zip_path)
          entries_map = {}
          return entries_map unless File.exist?(zip_path)

          Zip::File.open(zip_path) do |zip|
            zip.each do |entry|
              next if entry.directory?

              entries_map[entry.name] = entry.size
            end
          end
          entries_map
        end

        def detect_duplicates_across_other_layers(current_layer, current_entries, duplicates)
          @application.layers.each do |other_layer|
            next if other_layer.name == current_layer.name

            other_zip = File.join(@source_dir, 'build', 'artifacts', 'layers', "#{other_layer.name}.zip")
            next unless File.exist?(other_zip)

            other_entries = extract_zip_entries(other_zip)
            current_entries.each do |path, size|
              next unless other_entries.key?(path)

              duplicates << {
                'path' => path,
                'size' => size,
                'duplicated_in' => ["layer:#{other_layer.name}"],
                'recommendation' => "File is present in both layer '#{current_layer.name}' and layer " \
                                    "'#{other_layer.name}'. Consolidate into a single shared layer."
              }
            end
          end
        end

        def detect_duplicates_across_functions(current_layer, current_entries, duplicates)
          @application.functions.each do |fn|
            fn_name = fn.respond_to?(:logical_name) ? fn.logical_name : fn.name
            fn_zip = File.join(@source_dir, 'build', 'artifacts', 'functions', "#{fn_name}.zip")
            if File.exist?(fn_zip)
              check_duplicates_against_zip(fn_name, current_layer.name, current_entries, fn_zip, duplicates)
            else
              check_duplicates_against_function_source(fn_name, current_layer.name, current_entries, duplicates)
            end
          end
        end

        def check_duplicates_against_zip(fn_name, layer_name, current_entries, fn_zip, duplicates)
          fn_entries = extract_zip_entries(fn_zip)
          fn_entries.each do |path, size|
            norm_path = normalize_path_for_comparison(path)
            matching_layer_path = current_entries.keys.find do |lp|
              normalize_path_for_comparison(lp) == norm_path
            end

            next unless matching_layer_path

            duplicates << {
              'path' => path,
              'size' => size,
              'duplicated_in' => ["function:#{fn_name}"],
              'recommendation' => "Exclude '#{path}' from function '#{fn_name}' bundle since it is already " \
                                  "provided by layer '#{layer_name}'."
            }
          end
        end

        def check_duplicates_against_function_source(fn_name, layer_name, current_entries, duplicates)
          candidate_dirs = [
            File.join(@source_dir, 'vendor', 'bundle'),
            File.join(@source_dir, 'node_modules'),
            File.join(@source_dir, 'site-packages')
          ]

          candidate_dirs.each do |dir|
            next unless File.directory?(dir)

            Dir.glob(File.join(dir, '**', '*')).each do |file_path|
              next if File.directory?(file_path)

              rel_path = file_path.sub(%r{^#{Regexp.escape(@source_dir)}/?}, '')
              norm_path = normalize_path_for_comparison(rel_path)

              matched_lp = current_entries.keys.find do |lp|
                normalize_path_for_comparison(lp) == norm_path
              end

              next unless matched_lp

              duplicates << {
                'path' => rel_path,
                'size' => File.size(file_path),
                'duplicated_in' => ["function:#{fn_name}"],
                'recommendation' => "Exclude '#{rel_path}' from function '#{fn_name}' package since it is provided " \
                                    "by layer '#{layer_name}'."
              }
            end
          end
        end

        def normalize_path_for_comparison(path)
          p = path.to_s
          p = p.sub(%r{^(?:ruby/gems/\d+\.\d+\.\d+/gems|vendor/bundle/ruby/\d+\.\d+\.\d+/gems)/}, '')
          p = p.sub(%r{^(?:python/lib/python\d+\.\d+/site-packages|site-packages)/}, '')
          p.sub(%r{^(?:nodejs/node_modules|node_modules)/}, '')
        end

        def fetch_published_versions(layer)
          client = resolve_aws_client
          return [] unless client

          layer_names_to_try = [
            "#{@application.name}-#{layer.name}",
            layer.name.to_s,
            Compiler::LogicalId.for_layer_version(layer.name)
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
                'description' => v.description.to_s,
                'compatible_runtimes' => Array(v.compatible_runtimes).map(&:to_s),
                'compatible_architectures' => Array(v.compatible_architectures).map(&:to_s)
              }
            end
            break unless versions.empty?
          rescue StandardError => e
            # AWS未認証、権限不足、Layer不在等の場合は次の候補を試すか空リストで継続
            record_debug("Error fetching layer versions for '#{name}': #{e.message}")
          end

          versions.sort_by { |v| -v['version'] }
        end

        def resolve_aws_client
          return @aws_client if @aws_client

          begin
            require 'aws-sdk-lambda'
            Aws::Lambda::Client.new(region: @application.region)
          rescue LoadError, StandardError => e
            record_debug("Aws::Lambda::Client could not be initialized: #{e.message}")
            nil
          end
        end

        def evaluate_reuse(content_hash, published_versions)
          if published_versions.empty?
            return {
              reusable: false,
              matched_version: nil,
              matched_arn: nil,
              reason: 'No published versions found on AWS. A new layer version will be published on initial deploy.'
            }
          end

          matched = published_versions.find do |v|
            desc = v['description'].to_s
            desc.include?(content_hash) || desc.include?("hash:#{content_hash}")
          end

          if matched
            {
              reusable: true,
              matched_version: matched['version'],
              matched_arn: matched['layer_version_arn'],
              reason: "Matching content hash '#{content_hash[0..11]}' found in published version " \
                      "#{matched['version']}. Layer can be reused without rebuilding."
            }
          else
            {
              reusable: false,
              matched_version: nil,
              matched_arn: nil,
              reason: "No published version matches current content hash '#{content_hash[0..11]}'. " \
                      'A new layer version will be published on next deploy.'
            }
          end
        end

        def record_debug(msg)
          # 必要に応じてログや診断情報に記録
        end
      end
    end
  end
end
