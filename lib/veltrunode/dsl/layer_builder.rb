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

      def pip(requirements: 'requirements.txt')
        @build_environment['requirements'] = requirements.to_s
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

      def retain(policy = { latest: 5 })
        @retention_policy = policy
      end

      def compatible_runtimes(runtimes)
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
