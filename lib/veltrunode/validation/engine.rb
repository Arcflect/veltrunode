# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'
require_relative '../graph/resource_graph'
require_relative '../model/capability_expander'

module Veltrunode
  module Validation
    class Engine
      NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

      def self.run(application)
        new(application).run
      end

      def self.run!(application)
        new(application).run!
      end

      def initialize(application)
        @application = application
      end

      def run
        diagnostics = []

        diagnostics.concat(validate_resource_names)
        diagnostics.concat(validate_graph_and_references)
        diagnostics.concat(validate_runtime_compatibility)
        diagnostics.concat(validate_model_invariants)
        diagnostics.concat(validate_iam_capabilities)

        deduplicate_diagnostics(diagnostics)
      end

      def run!
        diagnostics = run
        errors = diagnostics.select { |d| d.severity == :error }
        return diagnostics if errors.empty?

        msg = "Validation failed with #{errors.size} error(s): #{errors.first.summary}"
        raise ValidationError.new(msg, diagnostics: diagnostics)
      end

      private

      attr_reader :application

      def validate_resource_names
        diagnostics = []

        check_name(application.name, 'Application', diagnostics)

        Array(application.functions).each do |fn|
          check_name(fn.logical_name, "Function '#{fn.logical_name}'", diagnostics)
        end

        Array(application.layers).each do |layer|
          check_name(layer.name, "Layer '#{layer.name}'", diagnostics)
        end

        Array(application.mounts).each do |mount|
          check_name(mount.symbolic_name, "EfsMount '#{mount.symbolic_name}'", diagnostics)
        end

        Array(application.schedules).each do |sched|
          check_name(sched.name, "Schedule '#{sched.name}'", diagnostics)
        end

        diagnostics
      end

      def check_name(name, entity_label, diagnostics)
        return if name.nil? || name.match?(NAME_PATTERN)

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-INVALID-NAME',
          severity: :error,
          summary: "#{entity_label} has an invalid name '#{name}'. Names must match [a-zA-Z0-9_-].",
          suggested_action: 'Rename the resource using only alphanumeric characters, hyphens, and underscores.',
          evidence: { 'name' => name.to_s }
        )
      end

      def validate_graph_and_references
        Graph::ResourceGraph.new(application, validate: true)
        []
      rescue ValidationError => e
        e.diagnostics
      end

      def validate_runtime_compatibility
        diagnostics = []
        layer_map = Array(application.layers).to_h { |layer| [layer.name, layer] }

        Array(application.functions).each do |fn|
          fn_runtime = fn.runtime
          next if fn_runtime.nil? || fn_runtime.empty?

          Array(fn.layers).each do |layer_ref|
            layer_name = extract_name_string(layer_ref)
            layer = layer_map[layer_name]
            next unless layer

            compat_runtimes = Array(layer.compatible_runtimes).map(&:to_s)
            next if compat_runtimes.empty? || runtime_matches?(fn_runtime, compat_runtimes)

            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-LAYER-001',
              severity: :error,
              summary: "Function '#{fn.logical_name}' uses runtime '#{fn_runtime}' incompatible " \
                       "with Layer '#{layer.name}'.",
              suggested_action: "Use a compatible runtime for function '#{fn.logical_name}' " \
                                "or update layer '#{layer.name}'.",
              evidence: {
                'function' => fn.logical_name,
                'runtime' => fn_runtime,
                'layer' => layer.name,
                'compatible' => compat_runtimes
              }
            )
          end
        end

        diagnostics
      end

      def runtime_matches?(fn_runtime, compat_runtimes)
        compat_runtimes.any? do |cr|
          cr == fn_runtime ||
            "ruby#{cr}" == fn_runtime ||
            fn_runtime.sub('ruby', '') == cr
        end
      end

      def validate_model_invariants
        diagnostics = []
        context = {
          available_layer_names: Array(application.layers).map(&:name),
          available_mount_names: Array(application.mounts).map(&:symbolic_name),
          available_layers: Array(application.layers)
        }

        Array(application.functions).each do |fn|
          diagnostics.concat(fn.validate_invariants(context)) if fn.respond_to?(:validate_invariants)
        end

        [application.layers, application.mounts, application.schedules].each do |collection|
          Array(collection).each do |item|
            item.validate if item.respond_to?(:validate)
          rescue ValidationError => e
            diagnostics.concat(e.diagnostics)
          end
        end

        diagnostics
      end

      def validate_iam_capabilities
        diagnostics = []
        expander = Model::CapabilityExpander.new(
          stage: application.stage,
          region: application.region,
          account: application.account_constraint
        )

        Array(application.functions).each do |fn|
          Array(fn.iam_capabilities).each do |cap|
            statements = expander.expand(cap)
            diagnostics.concat(expander.check_wildcards(statements))
          rescue ValidationError => e
            diagnostics.concat(e.diagnostics)
          end
        end

        diagnostics
      end

      def extract_name_string(item)
        val = if item.is_a?(Hash)
                item[:name] || item['name'] || item[:logical_name] ||
                  item['logical_name'] || item[:symbolic_name] || item['symbolic_name']
              elsif item.respond_to?(:logical_name)
                item.logical_name
              elsif item.respond_to?(:symbolic_name)
                item.symbolic_name
              elsif item.respond_to?(:name)
                item.name
              elsif item.is_a?(String) || item.is_a?(Symbol)
                item
              end
        return nil if val.nil?

        s = val.to_s
        s.include?(':') ? s.split(':', 2).first : s
      end

      def deduplicate_diagnostics(diagnostics)
        diagnostics.uniq { |d| [d.code, d.severity, d.summary, d.evidence] }
      end
    end
  end
end
