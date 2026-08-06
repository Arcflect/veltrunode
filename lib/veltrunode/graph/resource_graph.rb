# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Graph
    class ResourceGraph
      attr_reader :application, :nodes, :dependencies, :dependents

      def self.build(application, validate: true)
        new(application, validate: validate)
      end

      def initialize(application, validate: true)
        @application = application
        @nodes = {}
        @node_types = {}
        @dependencies = Hash.new { |h, k| h[k] = [] }
        @dependents = Hash.new { |h, k| h[k] = [] }

        build_graph
        validate! if validate
      end

      def validate!
        diagnostics = []
        diagnostics.concat(validate_references)
        diagnostics.concat(validate_cycles)

        return if diagnostics.empty?

        msg = "Resource graph validation failed: #{diagnostics.first.summary}"
        raise ValidationError.new(msg, diagnostics: diagnostics)
      end

      def depends_on(node_or_name)
        name = extract_name_string(node_or_name)
        @dependencies[name].map { |dep_name| @nodes[dep_name] }.compact
      end

      def depends_on_names(node_or_name)
        name = extract_name_string(node_or_name)
        @dependencies[name].dup
      end

      def topological_sort
        build_order
      end

      def build_order
        in_degree = {}
        @nodes.each_key { |name| in_degree[name] = 0 }
        @dependencies.each do |node_name, deps|
          in_degree[node_name] = deps.size
        end

        queue = @nodes.keys.select { |name| in_degree[name].zero? }
        order = []

        until queue.empty?
          curr = queue.shift
          order << @nodes[curr]

          @dependents[curr].each do |dep_node|
            in_degree[dep_node] -= 1
            queue << dep_node if in_degree[dep_node].zero?
          end
        end

        if order.size < @nodes.size
          unresolved = @nodes.keys - order.map { |n| extract_name_string(n) }
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-GRAPH-001',
            severity: :error,
            summary: "Circular dependency detected involving nodes: #{unresolved.join(', ')}",
            suggested_action: 'Remove circular dependencies between resources.',
            evidence: { 'unresolved_nodes' => unresolved }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end

        order
      end

      private

      def build_graph
        Array(application.layers).each do |layer|
          name = extract_name_string(layer)
          @nodes[name] = layer
          @node_types[name] = :layer
        end

        Array(application.mounts).each do |mount|
          name = extract_name_string(mount)
          @nodes[name] = mount
          @node_types[name] = :mount
        end

        Array(application.functions).each do |fn|
          name = extract_name_string(fn)
          @nodes[name] = fn
          @node_types[name] = :function
        end

        Array(application.schedules).each do |sched|
          name = extract_name_string(sched)
          @nodes[name] = sched
          @node_types[name] = :schedule
        end

        Array(application.functions).each do |fn|
          fn_name = extract_name_string(fn)

          Array(fn.layers).each do |layer_ref|
            layer_name = extract_name_string(layer_ref)
            add_edge(from: fn_name, to: layer_name)
          end

          Array(fn.mounts).each do |mount_ref|
            mount_name = extract_name_string(mount_ref)
            add_edge(from: fn_name, to: mount_name)
          end
        end

        Array(application.schedules).each do |sched|
          sched_name = extract_name_string(sched)
          next unless sched.target_function

          fn_name = extract_name_string(sched.target_function)
          add_edge(from: sched_name, to: fn_name)
        end
      end

      def add_edge(from:, to:)
        return if from.nil? || to.nil?

        @dependencies[from] << to unless @dependencies[from].include?(to)
        @dependents[to] << from unless @dependents[to].include?(from)
      end

      def validate_references
        diagnostics = []

        Array(application.functions).each do |fn|
          fn_name = extract_name_string(fn)

          Array(fn.layers).each do |layer_ref|
            layer_name = extract_name_string(layer_ref)
            next if @nodes.key?(layer_name) && @node_types[layer_name] == :layer

            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-REF-001',
              severity: :error,
              summary: "Function '#{fn_name}' references non-existent Layer '#{layer_name}'.",
              suggested_action: "Define layer '#{layer_name}' in application or fix reference.",
              evidence: { 'function' => fn_name, 'referenced_layer' => layer_name }
            )
          end

          Array(fn.mounts).each do |mount_ref|
            mount_name = extract_name_string(mount_ref)
            next if @nodes.key?(mount_name) && @node_types[mount_name] == :mount

            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-REF-001',
              severity: :error,
              summary: "Function '#{fn_name}' references non-existent EfsMount '#{mount_name}'.",
              suggested_action: "Define efs_mount '#{mount_name}' in application or fix reference.",
              evidence: { 'function' => fn_name, 'referenced_mount' => mount_name }
            )
          end
        end

        Array(application.schedules).each do |sched|
          sched_name = extract_name_string(sched)
          target_fn = extract_name_string(sched.target_function)

          next if target_fn.nil? || (@nodes.key?(target_fn) && @node_types[target_fn] == :function)

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-REF-001',
            severity: :error,
            summary: "Schedule '#{sched_name}' references non-existent Function '#{target_fn}'.",
            suggested_action: "Define function '#{target_fn}' in application or fix reference.",
            evidence: { 'schedule' => sched_name, 'referenced_function' => target_fn }
          )
        end

        diagnostics
      end

      def validate_cycles
        diagnostics = []
        visited = {}
        rec_stack = {}

        @nodes.each_key do |node|
          next if visited[node]

          cycle_path = find_cycle_dfs(node, visited, rec_stack, [])
          next unless cycle_path

          cycle_str = cycle_path.join(' -> ')
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-GRAPH-001',
            severity: :error,
            summary: "Circular dependency detected: #{cycle_str}.",
            suggested_action: 'Remove circular dependencies between resources.',
            evidence: { 'cycle' => cycle_path }
          )
          break
        end

        diagnostics
      end

      def find_cycle_dfs(node, visited, rec_stack, path)
        visited[node] = true
        rec_stack[node] = true
        path.push(node)

        deps = @dependencies[node] || []
        deps.each do |dep|
          if !visited[dep]
            cycle = find_cycle_dfs(dep, visited, rec_stack, path)
            return cycle if cycle
          elsif rec_stack[dep]
            cycle_start = path.index(dep)
            return path[cycle_start..] + [dep]
          end
        end

        rec_stack[node] = false
        path.pop
        nil
      end

      def extract_name_string(item)
        if item.is_a?(Hash)
          item[:name] || item['name'] || item[:logical_name] ||
            item['logical_name'] || item[:symbolic_name] || item['symbolic_name']
        elsif item.respond_to?(:logical_name)
          item.logical_name
        elsif item.respond_to?(:symbolic_name)
          item.symbolic_name
        elsif item.respond_to?(:name)
          item.name
        elsif item.is_a?(String) || item.is_a?(Symbol)
          s = item.to_s
          s.include?(':') ? s.split(':', 2).first : s
        end
      end
    end
  end
end
