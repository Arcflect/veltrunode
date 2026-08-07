# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Graph
    class ResourceGraph
      attr_reader :application, :nodes, :typed_nodes, :dependencies, :dependents

      def self.build(application, validate: true)
        new(application, validate: validate)
      end

      def initialize(application, validate: true)
        @application = application
        @nodes = {} # typed_key ("type:name") => model object
        @typed_nodes = { layer: {}, mount: {}, function: {}, schedule: {} }
        @dependencies = Hash.new { |h, k| h[k] = [] } # typed_key => [typed_keys]
        @dependents = Hash.new { |h, k| h[k] = [] }   # typed_key => [typed_keys]

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
        key = resolve_typed_key(node_or_name)
        return [] unless key

        @dependencies[key].map { |dep_key| @nodes[dep_key] }.compact
      end

      def depends_on_names(node_or_name)
        key = resolve_typed_key(node_or_name)
        return [] unless key

        @dependencies[key].map { |dep_key| extract_raw_name(dep_key) }
      end

      def topological_sort
        build_order
      end

      def build_order
        in_degree = {}
        @nodes.each_key { |key| in_degree[key] = 0 }
        @dependencies.each do |key, deps|
          in_degree[key] = deps.size
        end

        queue = @nodes.keys.select { |key| in_degree[key].zero? }
        order = []

        until queue.empty?
          curr = queue.shift
          order << @nodes[curr]

          @dependents[curr].each do |dep_key|
            in_degree[dep_key] -= 1
            queue << dep_key if in_degree[dep_key].zero?
          end
        end

        if order.size < @nodes.size
          unresolved = @nodes.keys - order.map { |k| @nodes[k] ? extract_name_string(@nodes[k]) : k }
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
        register_nodes(:layer, application.layers)
        register_nodes(:mount, application.mounts)
        register_nodes(:function, application.functions)
        register_nodes(:schedule, application.schedules)

        register_edges
      end

      def register_nodes(type, collection)
        Array(collection).each do |item|
          name = extract_name_string(item)
          next if name.nil?

          key = typed_key(type, name)
          @nodes[key] = item
          @typed_nodes[type][name] = item
        end
      end

      def register_edges
        Array(application.functions).each do |fn|
          fn_name = extract_name_string(fn)
          fn_key = typed_key(:function, fn_name)

          Array(fn.layers).each do |layer_ref|
            layer_name = extract_name_string(layer_ref)
            add_edge(from: fn_key, to: typed_key(:layer, layer_name))
          end

          Array(fn.mounts).each do |mount_ref|
            mount_name = extract_name_string(mount_ref)
            add_edge(from: fn_key, to: typed_key(:mount, mount_name))
          end
        end

        Array(application.schedules).each do |sched|
          sched_name = extract_name_string(sched)
          next unless sched.target_function

          fn_name = extract_name_string(sched.target_function)
          add_edge(from: typed_key(:schedule, sched_name), to: typed_key(:function, fn_name))
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
            next if @typed_nodes[:layer].key?(layer_name)

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
            next if @typed_nodes[:mount].key?(mount_name)

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

          next if target_fn.nil? || @typed_nodes[:function].key?(target_fn)

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

        @nodes.each_key do |node_key|
          next if visited[node_key]

          cycle_path = find_cycle_dfs(node_key, visited, rec_stack, [])
          next unless cycle_path

          cycle_str = cycle_path.map { |k| extract_raw_name(k) }.join(' -> ')
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

      def find_cycle_dfs(node_key, visited, rec_stack, path)
        visited[node_key] = true
        rec_stack[node_key] = true
        path.push(node_key)

        deps = @dependencies[node_key] || []
        deps.each do |dep|
          if !visited[dep]
            cycle = find_cycle_dfs(dep, visited, rec_stack, path)
            return cycle if cycle
          elsif rec_stack[dep]
            cycle_start = path.index(dep)
            return path[cycle_start..] + [dep]
          end
        end

        rec_stack[node_key] = false
        path.pop
        nil
      end

      def typed_key(type, name)
        "#{type}:#{name}"
      end

      def extract_raw_name(key)
        key.to_s.split(':', 2).last
      end

      def resolve_typed_key(node_or_name)
        case node_or_name
        when Model::Layer
          typed_key(:layer, extract_name_string(node_or_name))
        when Model::EfsMount
          typed_key(:mount, extract_name_string(node_or_name))
        when Model::Function
          typed_key(:function, extract_name_string(node_or_name))
        when Model::Schedule
          typed_key(:schedule, extract_name_string(node_or_name))
        else
          name = extract_name_string(node_or_name)
          @nodes.keys.find { |k| extract_raw_name(k) == name }
        end
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
    end
  end
end
