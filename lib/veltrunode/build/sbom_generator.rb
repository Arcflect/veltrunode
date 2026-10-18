# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative '../version'

module Veltrunode
  module Build
    # ビルド時に Gem の依存関係ツリー、バージョン、ライセンス情報を含む SBOM を生成するクラス
    class SbomGenerator
      CYCLONEDX_VERSION = '1.5'
      SPDX_VERSION = 'SPDX-2.3'

      class << self
        def generate(application:, source_dir:, output_path:, format: :cyclonedx, built_at: Time.now.utc)
          new(
            application: application,
            source_dir: source_dir,
            format: format,
            built_at: built_at
          ).generate(output_path)
        end

        def build_data(application:, source_dir:, format: :cyclonedx, built_at: Time.now.utc)
          new(
            application: application,
            source_dir: source_dir,
            format: format,
            built_at: built_at
          ).build_data
        end
      end

      attr_reader :application, :source_dir, :format, :built_at

      def initialize(application:, source_dir:, format: :cyclonedx, built_at: Time.now.utc)
        @application = application
        @source_dir = File.expand_path(source_dir.to_s.empty? ? Dir.pwd : source_dir.to_s)
        @format = format.to_sym
        @built_at = built_at.is_a?(Time) ? built_at.utc : Time.parse(built_at.to_s).utc
      end

      def build_data
        specs = collect_all_gem_specs
        if @format == :spdx
          build_spdx(specs)
        else
          build_cyclonedx(specs)
        end
      end

      def generate(output_path)
        data = build_data
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, "#{JSON.pretty_generate(data)}\n")
        data
      end

      private

      def collect_all_gem_specs
        lockfiles = find_lockfiles
        return [] if lockfiles.empty?

        all_specs_map = {}
        lockfiles.each do |lock_path|
          next unless File.file?(lock_path)

          content = File.read(lock_path)
          next if content.strip.empty?

          begin
            parser = Bundler::LockfileParser.new(content)
            parser.specs.each do |spec|
              key = "#{spec.name}:#{spec.version}"
              all_specs_map[key] ||= spec
            end
          rescue StandardError => e
            warn "Failed to parse lockfile #{lock_path}: #{e.message}" if ENV['VELTRUNODE_ENV'] == 'development'
          end
        end

        all_specs_map.values.sort_by(&:name)
      end

      def find_lockfiles
        candidates = []

        # 1. レイヤー定義に指定された lockfile
        if @application.respond_to?(:layers) && @application.layers
          @application.layers.each do |layer|
            src_spec = layer.respond_to?(:source_spec) ? layer.source_spec : nil
            lockfile_val = src_spec.is_a?(Hash) ? (src_spec['lockfile'] || src_spec[:lockfile]) : nil
            candidates << File.expand_path(lockfile_val.to_s, @source_dir) if lockfile_val
          end
        end

        # 2. ソースディレクトリ直下の Gemfile.lock
        candidates << File.join(@source_dir, 'Gemfile.lock')
        candidates.uniq
      end

      # ==========================================
      # CycloneDX 1.5 形式の構築
      # ==========================================
      def build_cyclonedx(specs)
        app_name = @application&.name || 'veltrunode-application'
        app_ref = "pkg:generic/#{app_name}@1.0.0"

        components = specs.map { |spec| build_cyclonedx_component(spec) }
        dependencies = build_cyclonedx_dependencies(specs, app_ref)

        {
          'bomFormat' => 'CycloneDX',
          'specVersion' => CYCLONEDX_VERSION,
          'serialNumber' => "urn:uuid:#{SecureRandom.uuid}",
          'version' => 1,
          'metadata' => {
            'timestamp' => @built_at.iso8601,
            'tools' => [
              {
                'vendor' => 'Arcflect',
                'name' => 'Veltrunode',
                'version' => Veltrunode::VERSION
              }
            ],
            'component' => {
              'type' => 'application',
              'name' => app_name,
              'version' => '1.0.0',
              'bom-ref' => app_ref
            }
          },
          'components' => components,
          'dependencies' => dependencies
        }
      end

      def build_cyclonedx_component(spec)
        purl = "pkg:gem/#{spec.name}@#{spec.version}"
        licenses = resolve_licenses(spec.name, spec.version)

        component = {
          'type' => 'library',
          'name' => spec.name,
          'version' => spec.version.to_s,
          'purl' => purl,
          'bom-ref' => purl
        }

        if licenses.any?
          component['licenses'] = licenses.map do |lic|
            { 'license' => { 'id' => lic } }
          end
        end

        component
      end

      def build_cyclonedx_dependencies(specs, app_ref)
        specs_by_name = specs.to_h { |s| [s.name, s] }

        result = []

        # アプリケーション自体の依存
        direct_deps = specs
        # 直接依存している Gem
        result << {
          'ref' => app_ref,
          'dependsOn' => direct_deps.map { |s| "pkg:gem/#{s.name}@#{s.version}" }
        }

        # 各 Gem の依存関係
        specs.each do |spec|
          purl = "pkg:gem/#{spec.name}@#{spec.version}"
          dep_purls = spec.dependencies.map do |dep|
            dep_spec = specs_by_name[dep.name]
            dep_spec ? "pkg:gem/#{dep_spec.name}@#{dep_spec.version}" : "pkg:gem/#{dep.name}"
          end.sort

          result << {
            'ref' => purl,
            'dependsOn' => dep_purls
          }
        end

        result
      end

      # ==========================================
      # SPDX 2.3 形式の構築
      # ==========================================
      def build_spdx(specs)
        app_name = @application&.name || 'veltrunode-application'
        doc_spdx_id = 'SPDXRef-DOCUMENT'

        packages = specs.map { |spec| build_spdx_package(spec) }
        relationships = build_spdx_relationships(specs, doc_spdx_id)

        {
          'spdxVersion' => SPDX_VERSION,
          'dataLicense' => 'CC0-1.0',
          'SPDXID' => doc_spdx_id,
          'name' => app_name,
          'documentNamespace' => "https://veltrunode.arcflect.com/spdx/#{app_name}-#{SecureRandom.uuid}",
          'creationInfo' => {
            'created' => @built_at.iso8601,
            'creators' => [
              "Tool: Veltrunode-#{Veltrunode::VERSION}",
              'Organization: Arcflect'
            ]
          },
          'packages' => packages,
          'relationships' => relationships
        }
      end

      def build_spdx_package(spec)
        spdx_id = "SPDXRef-Package-#{sanitize_spdx_id(spec.name)}-#{sanitize_spdx_id(spec.version.to_s)}"
        purl = "pkg:gem/#{spec.name}@#{spec.version}"
        licenses = resolve_licenses(spec.name, spec.version)
        license_str = licenses.any? ? licenses.join(' OR ') : 'NOASSERTION'

        {
          'name' => spec.name,
          'SPDXID' => spdx_id,
          'versionInfo' => spec.version.to_s,
          'downloadLocation' => 'NOASSERTION',
          'filesAnalyzed' => false,
          'licenseConcluded' => license_str,
          'licenseDeclared' => license_str,
          'externalRefs' => [
            {
              'referenceCategory' => 'PACKAGE-MANAGER',
              'referenceType' => 'purl',
              'referenceLocator' => purl
            }
          ]
        }
      end

      def build_spdx_relationships(specs, doc_spdx_id)
        specs_by_name = specs.to_h { |s| [s.name, s] }
        relationships = []

        specs.each do |spec|
          parent_id = "SPDXRef-Package-#{sanitize_spdx_id(spec.name)}-#{sanitize_spdx_id(spec.version.to_s)}"

          relationships << {
            'spdxElementId' => doc_spdx_id,
            'relatedSpdxElement' => parent_id,
            'relationshipType' => 'DESCRIBES'
          }

          spec.dependencies.each do |dep|
            dep_spec = specs_by_name[dep.name]
            next unless dep_spec

            child_id = "SPDXRef-Package-#{sanitize_spdx_id(dep_spec.name)}-#{sanitize_spdx_id(dep_spec.version.to_s)}"
            relationships << {
              'spdxElementId' => parent_id,
              'relatedSpdxElement' => child_id,
              'relationshipType' => 'DEPENDS_ON'
            }
          end
        end

        relationships
      end

      def sanitize_spdx_id(str)
        str.to_s.gsub(/[^a-zA-Z0-9.-]/, '-')
      end

      # ==========================================
      # ライセンス解決
      # ==========================================
      def resolve_licenses(gem_name, gem_version)
        if defined?(Gem::Specification)
          # 完全一致
          specs = Gem::Specification.find_all_by_name(gem_name, "= #{gem_version}")
          specs = Gem::Specification.find_all_by_name(gem_name) if specs.empty?

          if (spec = specs.first)
            lics = Array(spec.licenses || spec.license).compact.map(&:to_s).reject(&:empty?)
            return lics unless lics.empty?
          end
        end

        # レイヤーの license_metadata が指定されている場合のフォールバック等
        []
      rescue StandardError
        []
      end
    end
  end
end
