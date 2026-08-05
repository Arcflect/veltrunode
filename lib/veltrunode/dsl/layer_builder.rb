# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/layer'

module Veltrunode
  module DSL
    class LayerBuilder < BaseBuilder
      def initialize(name, runtime_default: 'ruby3.3')
        super()
        @name = name.to_s
        @compatible_runtimes = [runtime_default]
        @source_spec = nil
        @architectures = [:x86_64]
        @build_environment = {}
        @retention_policy = { latest: 5 }
        @description = nil
        @license_metadata = nil
        @content_hash = nil
      end

      def bundle(lockfile: 'Gemfile.lock', without: %i[development test])
        @build_environment['lockfile'] = lockfile.to_s
        @build_environment['without'] = Array(without).map(&:to_s)
        @bundle ||= 'bundle'
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

      def architectures(archs)
        @architectures = Array(archs).map(&:to_sym)
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
    end
  end
end
