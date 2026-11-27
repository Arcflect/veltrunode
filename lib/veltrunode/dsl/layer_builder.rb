# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/layer'

module Veltrunode
  module DSL
    class LayerBuilder < BaseBuilder
      attr_reader :name

      def initialize(name, runtime_default: 'ruby3.3', architecture_default: :x86_64)
        super()
        @name = name.to_s
        @compatible_runtimes = [runtime_default]
        @explicit_runtimes = false
        @source_spec = nil
        @architectures = [normalize_architecture_symbol(architecture_default)]
        @explicit_architectures = false
        @build_environment = {}
        @retention_policy = { latest: 5 }
        @description = nil
        @license_metadata = nil
        @content_hash = nil
      end

      def explicit_architectures?
        @explicit_architectures
      end

      def apply_inferred_architectures(archs)
        return if @explicit_architectures

        flat = Array(archs).flatten.compact
        return if flat.empty?

        @architectures = flat.map { |a| normalize_architecture_symbol(a) }.uniq
      end

      def bundle(lockfile: 'Gemfile.lock', without: %i[development test])
        @build_environment['lockfile'] = lockfile.to_s
        @build_environment['without'] = Array(without).map(&:to_s)
        @bundle ||= 'bundle'
      end

      def pip(requirements: 'requirements.txt', pyproject: nil, uv: nil, only_binary: nil)
        ensure_python_default_runtime!
        @build_environment['requirements'] = requirements.to_s if requirements
        @build_environment['pyproject'] = pyproject.to_s if pyproject
        @build_environment['package_manager'] = 'uv' if uv
        @build_environment['only_binary'] = only_binary ? true : false unless only_binary.nil?
      end

      def uv(pyproject: nil, requirements: nil, lockfile: nil, without: %i[dev development test],
             groups: nil, extras: nil, only_binary: true, index_url: nil)
        ensure_python_default_runtime!
        @build_environment['package_manager'] = 'uv'
        if pyproject
          @build_environment['pyproject'] = pyproject.to_s
        elsif requirements
          @build_environment['requirements'] = requirements.to_s
        else
          @build_environment['pyproject'] = 'pyproject.toml'
        end
        @build_environment['requirements'] = requirements.to_s if requirements
        @build_environment['lockfile'] = lockfile.to_s if lockfile
        @build_environment['without'] = Array(without).map(&:to_s) if without
        @build_environment['groups'] = Array(groups).map(&:to_s) if groups
        @build_environment['extras'] = Array(extras).map(&:to_s) if extras
        @build_environment['only_binary'] = only_binary ? true : false
        @build_environment['index_url'] = index_url.to_s if index_url
      end

      def poetry(pyproject: 'pyproject.toml', lockfile: 'poetry.lock', without: %i[dev development test],
                 groups: nil, extras: nil, use_uv: true, only_binary: true)
        ensure_python_default_runtime!
        @build_environment['package_manager'] = 'poetry'
        @build_environment['pyproject'] = pyproject.to_s if pyproject
        @build_environment['lockfile'] = lockfile.to_s if lockfile
        @build_environment['without'] = Array(without).map(&:to_s) if without
        @build_environment['groups'] = Array(groups).map(&:to_s) if groups
        @build_environment['extras'] = Array(extras).map(&:to_s) if extras
        @build_environment['use_uv'] = use_uv ? true : false
        @build_environment['only_binary'] = only_binary ? true : false
      end

      def npm(package_json: 'package.json', package_lock: nil)
        @build_environment['package_json'] = package_json.to_s
        @build_environment['package_lock'] = package_lock.to_s if package_lock
      end

      def include_gems(gems)
        @build_environment['include_gems'] = Array(gems).map(&:to_s)
      end

      def build_on(platform)
        @build_environment['build_on'] = platform.to_s
      end

      def prebuilt(path)
        @build_environment['prebuilt_path'] = path.to_s
      end
      alias prebuilt_path prebuilt
      alias external_binaries prebuilt

      def no_docker(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @build_environment['no_docker'] = val ? true : false
      end
      alias dockerless no_docker

      def fallback_to_host(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @build_environment['fallback_to_host'] = val ? true : false
      end

      def retain(policy = { latest: 5 })
        @retention_policy = policy
      end

      def compatible_runtimes(runtimes)
        @explicit_runtimes = true
        @compatible_runtimes = Array(runtimes).map(&:to_s)
      end

      def architectures(*archs)
        flat = archs.flatten.compact
        return if flat.empty?

        @explicit_architectures = true
        @architectures = flat.map { |a| normalize_architecture_symbol(a) }.uniq
      end
      alias architecture architectures
      alias compatible_architectures architectures

      def add_architecture(*archs)
        flat = archs.flatten.compact
        return if flat.empty?

        @explicit_architectures = true
        added = flat.map { |a| normalize_architecture_symbol(a) }
        @architectures = (@architectures + added).uniq
      end

      def description(desc)
        @description = desc.to_s
      end

      def license(lic)
        @license_metadata = lic.to_s
      end

      def content_hash(hash)
        @content_hash = hash.to_s
      end

      def build
        Model::Layer.new(
          name: @name,
          compatible_runtimes: @compatible_runtimes,
          source_spec: @source_spec,
          architectures: @architectures,
          build_environment: @build_environment,
          retention_policy: @retention_policy,
          description: @description,
          license_metadata: @license_metadata,
          content_hash: @content_hash
        )
      end

      private

      def ensure_python_default_runtime!
        return if @explicit_runtimes
        return if @compatible_runtimes.any? { |r| r.to_s.start_with?('python') }

        @compatible_runtimes = ['python3.12']
      end

      def normalize_architecture_symbol(arch)
        case arch.to_s.strip.downcase
        when 'arm64', 'aarch64'
          :arm64
        when 'x86_64', 'amd64', ''
          :x86_64
        else
          arch.to_s.to_sym
        end
      end
    end
  end
end
