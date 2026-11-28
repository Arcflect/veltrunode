# frozen_string_literal: true

require 'bundler'
begin
  require 'zip'
rescue LoadError
  nil
end
require_relative '../../diagnostics'

module Veltrunode
  module AWS
    module Inspectors
      # 各 Lambda 関数にアタッチされた Layer と提供される Gem（バージョン・サイズ・ライセンス・依存関係）の
      # ツリー構築および複数 Layer 間のライブラリ競合・重複検出を行うインスペクタ
      class LayerTreeInspector
        # 個別 Gem / ライブラリノード
        class GemNode
          attr_reader :name,
                      :version,
                      :size_bytes,
                      :license,
                      :dependencies,
                      :conflict,
                      :conflict_type,
                      :conflicting_layers

          def initialize(
            name:,
            version:,
            size_bytes: 0,
            license: 'UNKNOWN',
            dependencies: [],
            conflict: false,
            conflict_type: nil,
            conflicting_layers: []
          )
            @name = name.to_s.freeze
            @version = (version.nil? || version.to_s.strip.empty? ? 'unknown' : version.to_s).freeze
            @size_bytes = size_bytes.to_i
            @license = (license.nil? || license.to_s.strip.empty? ? 'UNKNOWN' : license.to_s).freeze
            @dependencies = Array(dependencies).freeze
            @conflict = conflict ? true : false
            @conflict_type = conflict_type&.to_sym
            @conflicting_layers = Array(conflicting_layers).freeze
            freeze
          end

          def conflict?
            @conflict
          end

          def formatted_size
            LayerTreeInspector.format_size(@size_bytes)
          end

          def with_conflict(conflict:, conflict_type:, conflicting_layers:, dependencies: @dependencies)
            self.class.new(
              name: @name,
              version: @version,
              size_bytes: @size_bytes,
              license: @license,
              dependencies: dependencies,
              conflict: conflict,
              conflict_type: conflict_type,
              conflicting_layers: conflicting_layers
            )
          end

          def to_h
            {
              'name' => @name,
              'version' => @version,
              'size_bytes' => @size_bytes,
              'formatted_size' => formatted_size,
              'license' => @license,
              'conflict' => @conflict,
              'conflict_type' => @conflict_type&.to_s,
              'conflicting_layers' => @conflicting_layers,
              'dependencies' => @dependencies.map(&:to_h)
            }
          end
        end

        # Layer ノード
        class LayerNode
          attr_reader :layer_name,
                      :description,
                      :compatible_runtimes,
                      :architectures,
                      :total_size_bytes,
                      :gems,
                      :root_gems

          def initialize(
            layer_name:,
            compatible_runtimes: [],
            architectures: [],
            description: nil,
            total_size_bytes: nil,
            gems: [],
            root_gems: nil
          )
            @layer_name = layer_name.to_s.freeze
            @description = description&.to_s&.freeze
            @compatible_runtimes = Array(compatible_runtimes).map(&:to_s).freeze
            @architectures = Array(architectures).map(&:to_s).freeze
            @gems = Array(gems).freeze
            @root_gems = Array(root_gems || @gems).freeze
            @total_size_bytes = (total_size_bytes || @gems.sum(&:size_bytes)).to_i
            freeze
          end

          def formatted_total_size
            LayerTreeInspector.format_size(@total_size_bytes)
          end

          def to_h
            {
              'layer_name' => @layer_name,
              'description' => @description,
              'compatible_runtimes' => @compatible_runtimes,
              'architectures' => @architectures,
              'total_size_bytes' => @total_size_bytes,
              'formatted_total_size' => formatted_total_size,
              'gems_count' => @gems.size,
              'gems' => @gems.map(&:to_h),
              'root_gems' => @root_gems.map(&:to_h)
            }
          end
        end

        # Function ノード
        class FunctionNode
          attr_reader :function_name,
                      :runtime,
                      :architecture,
                      :layers,
                      :conflicts

          def initialize(
            function_name:,
            runtime:,
            architecture:,
            layers: [],
            conflicts: []
          )
            @function_name = function_name.to_s.freeze
            @runtime = runtime.to_s.freeze
            @architecture = architecture.to_s.freeze
            @layers = Array(layers).freeze
            @conflicts = Array(conflicts).freeze
            freeze
          end

          def to_h
            {
              'function_name' => @function_name,
              'runtime' => @runtime,
              'architecture' => @architecture,
              'layers' => @layers.map(&:to_h),
              'conflicts' => @conflicts
            }
          end
        end

        # ツリー検査結果レポート
        class Report
          attr_reader :application_name,
                      :stage,
                      :region,
                      :functions,
                      :layers,
                      :unattached_layers,
                      :conflicts,
                      :diagnostics

          def initialize(
            application_name:,
            stage:,
            region:,
            functions: [],
            layers: [],
            unattached_layers: [],
            conflicts: [],
            diagnostics: []
          )
            @application_name = application_name.to_s.freeze
            @stage = stage.to_s.freeze
            @region = region.to_s.freeze
            @functions = Array(functions).freeze
            @layers = Array(layers).freeze
            @unattached_layers = Array(unattached_layers).freeze
            @conflicts = Array(conflicts).freeze
            @diagnostics = Array(diagnostics).freeze
            freeze
          end

          def conflicts?
            !@conflicts.empty?
          end

          def render_ascii_tree
            LayerTreeInspector.render_ascii_tree(self)
          end

          def to_h
            {
              'application_name' => @application_name,
              'stage' => @stage,
              'region' => @region,
              'functions' => @functions.map(&:to_h),
              'layers' => @layers.map(&:to_h),
              'unattached_layers' => @unattached_layers.map(&:to_h),
              'conflicts' => @conflicts
            }
          end
        end

        class << self
          def inspect(application, target_name: nil, source_dir: Dir.pwd)
            new(
              application: application,
              target_name: target_name,
              source_dir: source_dir
            ).inspect
          end

          def format_size(bytes)
            b = bytes.to_i
            if b >= 1_048_576
              format('%.1f MB', b / 1_048_576.0)
            elsif b >= 1_024
              format('%.1f KB', b / 1_024.0)
            else
              "#{b} B"
            end
          end

          def render_ascii_tree(report)
            lines = []
            lines << ('=' * 88)
            lines << "  Veltrunode Layer Dependency Tree (#{report.application_name})"
            lines << ('=' * 88)
            lines << "#{report.application_name} (stage: #{report.stage}, region: #{report.region})"

            top_items = report.functions.map { |fn| [:function, fn] } +
                        report.unattached_layers.map { |ly| [:unattached_layer, ly] }

            if top_items.empty?
              lines << '└── (No functions or layers defined)'
            else
              top_items.each_with_index do |(kind, item), idx|
                last_top = idx == top_items.size - 1
                if kind == :function
                  render_function_node(lines, item, is_last: last_top)
                else
                  render_unattached_layer_node(lines, item, is_last: last_top)
                end
              end
            end

            append_conflicts_summary(lines, report)
            lines << ('=' * 88)
            lines.join("\n")
          end

          private

          def render_function_node(lines, fn_node, is_last:)
            connector = is_last ? '└── ' : '├── '
            child_prefix = is_last ? '    ' : '│   '
            fn_meta = [fn_node.runtime, fn_node.architecture].reject(&:empty?).join(', ')
            meta_str = fn_meta.empty? ? '' : " (#{fn_meta})"
            lines << "#{connector}Function: #{fn_node.function_name}#{meta_str}"

            if fn_node.layers.empty?
              lines << "#{child_prefix}└── (no layers attached)"
              return
            end

            fn_node.layers.each_with_index do |layer_node, l_idx|
              last_layer = l_idx == fn_node.layers.size - 1
              render_layer_node(lines, layer_node, prefix: child_prefix, is_last: last_layer)
            end
          end

          def render_unattached_layer_node(lines, layer_node, is_last:)
            render_layer_node(lines, layer_node, prefix: '', is_last: is_last, unattached: true)
          end

          def render_layer_node(lines, layer_node, prefix:, is_last:, unattached: false)
            connector = is_last ? '└── ' : '├── '
            child_prefix = "#{prefix}#{is_last ? '    ' : '│   '}"
            tag = unattached ? 'Layer (unattached)' : 'Layer'
            rt_str = layer_node.compatible_runtimes.join(', ')
            info_parts = []
            info_parts << "runtimes: #{rt_str}" unless rt_str.empty?
            info_parts << "total: #{layer_node.formatted_total_size}"
            info_parts_str = info_parts.empty? ? '' : " (#{info_parts.join(', ')})"

            lines << "#{prefix}#{connector}#{tag}: #{layer_node.layer_name}#{info_parts_str}"

            if layer_node.root_gems.empty?
              lines << "#{child_prefix}└── (no gems)"
              return
            end

            layer_node.root_gems.each_with_index do |gem_node, g_idx|
              last_gem = g_idx == layer_node.root_gems.size - 1
              render_gem_node(lines, gem_node, prefix: child_prefix, is_last: last_gem)
            end
          end

          def render_gem_node(lines, gem_node, prefix:, is_last:)
            connector = is_last ? '└── ' : '├── '
            child_prefix = "#{prefix}#{is_last ? '    ' : '│   '}"

            conflict_badge = format_conflict_badge(gem_node)
            lines << "#{prefix}#{connector}#{gem_node.name} (#{gem_node.version}) " \
                     "[#{gem_node.formatted_size}, license: #{gem_node.license}]#{conflict_badge}"

            gem_node.dependencies.each_with_index do |dep_node, d_idx|
              last_dep = d_idx == gem_node.dependencies.size - 1
              render_gem_node(lines, dep_node, prefix: child_prefix, is_last: last_dep)
            end
          end

          def format_conflict_badge(gem_node)
            return '' unless gem_node.conflict?

            others = gem_node.conflicting_layers.map do |c|
              "#{c['layer_name']} (#{c['version']})"
            end.join(', ')

            label = gem_node.conflict_type == :version_mismatch ? 'CONFLICT: version mismatch' : 'CONFLICT: duplicate'
            others.empty? ? " ⚠️ [#{label}]" : " ⚠️ [#{label} with #{others}]"
          end

          def append_conflicts_summary(lines, report)
            lines << ''
            if report.conflicts.empty?
              lines << 'Conflicts: None detected.'
              return
            end

            lines << "Conflicts Detected (#{report.conflicts.size}):"
            report.conflicts.each do |conflict|
              layer_details = Array(conflict['layers']).map do |l|
                "#{l['layer_name']} (#{l['version']})"
              end.join(', ')
              type_label = conflict['conflict_type'] == 'version_mismatch' ? 'VERSION MISMATCH' : 'DUPLICATE'
              fn_scope = Array(conflict['affected_functions'])
              fn_suffix = fn_scope.empty? ? '' : " [functions: #{fn_scope.join(', ')}]"
              lines << "  ⚠️ [#{type_label}] #{conflict['gem_name']}: #{layer_details}#{fn_suffix}"
            end
          end
        end

        def initialize(application:, target_name: nil, source_dir: Dir.pwd)
          @application = application
          @target_name = target_name&.to_s&.strip
          @target_name = nil if @target_name && @target_name.empty?
          @source_dir = File.expand_path(source_dir.to_s.empty? ? Dir.pwd : source_dir.to_s)
          @size_cache = {}
          @license_cache = {}
          @diagnostics = []
        end

        def inspect
          validate_target_name! if @target_name

          raw_layers_map = build_raw_layers_map
          conflicts = detect_conflicts(raw_layers_map)
          annotated_layers_map = annotate_layers_with_conflicts(raw_layers_map, conflicts)

          functions_to_include = select_functions
          function_nodes = functions_to_include.map do |fn|
            build_function_node(fn, annotated_layers_map)
          end

          attached_layer_names = functions_to_include.flat_map { |fn| Array(fn.layers).map(&:to_s) }.uniq
          all_selected_layers = select_layers(annotated_layers_map)
          unattached_layers = all_selected_layers.reject { |ln| attached_layer_names.include?(ln.layer_name) }

          Report.new(
            application_name: @application.respond_to?(:name) ? @application.name : 'application',
            stage: @application.respond_to?(:stage) ? @application.stage : 'dev',
            region: @application.respond_to?(:region) ? @application.region : 'ap-northeast-1',
            functions: function_nodes,
            layers: all_selected_layers,
            unattached_layers: unattached_layers,
            conflicts: conflicts,
            diagnostics: @diagnostics
          )
        end

        private

        def validate_target_name!
          fn_match = Array(@application.functions).any? { |f| extract_fn_name(f) == @target_name }
          layer_match = Array(@application.layers).any? { |l| l.name.to_s == @target_name }
          return if fn_match || layer_match

          app_name = @application.respond_to?(:name) ? @application.name : 'application'
          raise ArgumentError,
                "Function or Layer '#{@target_name}' not found in application '#{app_name}'."
        end

        def select_functions
          all_fns = Array(@application.functions)
          return all_fns unless @target_name

          exact_fns = all_fns.select { |f| extract_fn_name(f) == @target_name }
          return exact_fns unless exact_fns.empty?

          # target_name が Layer 名の場合は、その Layer をアタッチしている関数を抽出
          all_fns.select { |f| Array(f.layers).map(&:to_s).include?(@target_name) }
        end

        def select_layers(annotated_layers_map)
          return annotated_layers_map.values unless @target_name

          if annotated_layers_map.key?(@target_name)
            [annotated_layers_map[@target_name]]
          else
            fn = Array(@application.functions).find { |f| extract_fn_name(f) == @target_name }
            return [] unless fn

            Array(fn.layers).map { |ln| annotated_layers_map[ln.to_s] }.compact
          end
        end

        def build_raw_layers_map
          map = {}
          Array(@application.layers).each do |layer|
            gems_info = extract_layer_gems(layer)
            map[layer.name.to_s] = {
              model: layer,
              gems: gems_info[:gems],
              deps_map: gems_info[:deps_map],
              zip_total_size: gems_info[:zip_total_size]
            }
          end
          map
        end

        def extract_layer_gems(layer)
          zip_data = inspect_existing_layer_zip(layer)
          explicit_gems = extract_explicit_gems_from_layer(layer)

          if explicit_gems.any?
            build_gems_from_explicit_list(layer, explicit_gems, zip_data)
          else
            build_gems_from_lockfile_or_zip(layer, zip_data)
          end
        end

        def layer_build_env(layer)
          layer.respond_to?(:build_environment) && layer.build_environment.is_a?(Hash) ? layer.build_environment : {}
        end

        def extract_explicit_gems_from_layer(layer)
          env = layer_build_env(layer)
          src = layer.respond_to?(:source_spec) && layer.source_spec.is_a?(Hash) ? layer.source_spec : {}

          raw = env['gems'] || env[:gems] || src['gems'] || src[:gems]
          Array(raw).compact
        end

        def build_gems_from_explicit_list(layer, explicit_gems, zip_data)
          gems = []
          deps_map = {}

          explicit_gems.each do |entry|
            if entry.is_a?(Hash)
              name = (entry['name'] || entry[:name]).to_s
              next if name.empty?

              version = (entry['version'] || entry[:version] || 'unknown').to_s
              size = entry['size_bytes'] || entry[:size_bytes] || entry['size'] || entry[:size] ||
                     zip_data[:gem_sizes]["#{name}-#{version}"] || resolve_gem_size(name, version)
              license = entry['license'] || entry[:license] ||
                        zip_data[:gem_licenses]["#{name}-#{version}"] || resolve_gem_license(layer, name, version)
              deps = Array(entry['dependencies'] || entry[:dependencies]).map(&:to_s)
              deps_map[name] = deps
            else
              name = entry.to_s
              version = resolve_installed_gem_version(name) || 'unknown'
              size = zip_data[:gem_sizes]["#{name}-#{version}"] || resolve_gem_size(name, version)
              license = zip_data[:gem_licenses]["#{name}-#{version}"] || resolve_gem_license(layer, name, version)
              deps_map[name] = []
            end
            gems << GemNode.new(name: name, version: version, size_bytes: size, license: license)
          end

          {
            gems: gems.sort_by(&:name),
            deps_map: deps_map,
            zip_total_size: zip_data[:total_size]
          }
        end

        def build_gems_from_lockfile_or_zip(layer, zip_data)
          lock_path = resolve_layer_lockfile(layer)
          parsed_specs = if lock_path && File.file?(lock_path)
                           parse_lockfile_specs(layer, File.read(lock_path), lock_path)
                         else
                           []
                         end

          include_list = extract_include_gems(layer)

          if parsed_specs.any?
            selected_specs = filter_specs_by_include_gems(parsed_specs, include_list)
            add_missing_included_gems(selected_specs, include_list) if include_list.any?

            deps_map = {}
            gems = selected_specs.map do |spec|
              name = spec[:name]
              version = spec[:version]
              full_name = "#{name}-#{version}"
              deps_map[name] = Array(spec[:dependencies])
              size = zip_data[:gem_sizes][full_name] || resolve_gem_size(name, version)
              license = zip_data[:gem_licenses][full_name] || resolve_gem_license(layer, name, version)
              GemNode.new(name: name, version: version, size_bytes: size, license: license)
            end

            {
              gems: gems.sort_by(&:name),
              deps_map: deps_map,
              zip_total_size: zip_data[:total_size]
            }
          elsif include_list.any?
            deps_map = {}
            gems = include_list.map do |name|
              version = zip_data[:gem_versions][name] || resolve_installed_gem_version(name) || 'unknown'
              full_name = "#{name}-#{version}"
              deps_map[name] = zip_data[:gem_deps][name] || resolve_installed_gem_deps(name, version)
              size = zip_data[:gem_sizes][full_name] || resolve_gem_size(name, version)
              license = zip_data[:gem_licenses][full_name] || resolve_gem_license(layer, name, version)
              GemNode.new(name: name, version: version, size_bytes: size, license: license)
            end

            {
              gems: gems.sort_by(&:name),
              deps_map: deps_map,
              zip_total_size: zip_data[:total_size]
            }
          elsif zip_data[:gem_versions].any?
            deps_map = {}
            gems = zip_data[:gem_versions].map do |name, version|
              full_name = "#{name}-#{version}"
              deps_map[name] = zip_data[:gem_deps][name] || []
              size = zip_data[:gem_sizes][full_name] || 0
              license = zip_data[:gem_licenses][full_name] || resolve_gem_license(layer, name, version)
              GemNode.new(name: name, version: version, size_bytes: size, license: license)
            end

            {
              gems: gems.sort_by(&:name),
              deps_map: deps_map,
              zip_total_size: zip_data[:total_size]
            }
          else
            { gems: [], deps_map: {}, zip_total_size: nil }
          end
        end

        def resolve_layer_lockfile(layer)
          env = layer_build_env(layer)
          src = layer.respond_to?(:source_spec) && layer.source_spec.is_a?(Hash) ? layer.source_spec : {}
          custom = env['lockfile'] || env[:lockfile] || src['lockfile'] || src[:lockfile]
          return File.expand_path(custom.to_s, @source_dir) if custom && !custom.to_s.strip.empty?

          default_lock = File.join(@source_dir, 'Gemfile.lock')
          File.file?(default_lock) ? default_lock : nil
        end

        def extract_include_gems(layer)
          env = layer_build_env(layer)
          Array(env['include_gems'] || env[:include_gems]).map(&:to_s).reject(&:empty?)
        end

        def parse_lockfile_specs(layer, lock_content, lock_path)
          specs = []
          begin
            parser = Bundler::LockfileParser.new(lock_content)
            specs = parser.specs.map do |s|
              {
                name: s.name.to_s,
                version: s.version.to_s,
                dependencies: Array(s.dependencies).map { |d| d.name.to_s }
              }
            end
          rescue StandardError
            specs = []
          end

          specs = parse_lockfile_with_regex(lock_content) if specs.empty?
          filter_specs_by_layer_groups(layer, specs, lock_path)
        end

        def parse_lockfile_with_regex(lock_content)
          specs = []
          in_specs = false
          current = nil

          lock_content.each_line do |line|
            if line =~ /\A\s{2}specs:\s*\z/
              in_specs = true
              next
            elsif in_specs && line =~ /\A[A-Z]/
              in_specs = false
              current = nil
              next
            end

            next unless in_specs

            if line =~ /\A\s{4}([a-zA-Z0-9_.-]+)\s+\(([^)]+)\)/
              raw_ver = Regexp.last_match(2).split('-').first
              current = {
                name: Regexp.last_match(1),
                version: raw_ver,
                dependencies: []
              }
              specs << current
            elsif current && line =~ /\A\s{6}([a-zA-Z0-9_.-]+)/
              current[:dependencies] << Regexp.last_match(1)
            end
          end

          specs
        end

        def filter_specs_by_layer_groups(layer, specs, lock_path)
          env = layer_build_env(layer)
          without_groups = Array(env['without'] || env[:without] || %w[development test]).map(&:to_s)
          only_groups = Array(env['groups'] || env[:groups]).map(&:to_s)

          gemfile_path = lock_path ? File.join(File.dirname(lock_path), 'Gemfile') : File.join(@source_dir, 'Gemfile')
          return specs unless File.file?(gemfile_path)

          groups_map = parse_gemfile_groups(gemfile_path)
          return specs if groups_map.empty?

          specs.reject do |spec|
            gem_groups = groups_map[spec[:name]] || ['default']
            if only_groups.any?
              !gem_groups.intersect?(only_groups)
            else
              gem_groups.intersect?(without_groups)
            end
          end
        end

        def parse_gemfile_groups(gemfile_path)
          groups_map = {}
          current_groups = ['default']

          File.foreach(gemfile_path) do |line|
            stripped = line.strip
            next if stripped.start_with?('#')

            case stripped
            when /\Agroup\s+(.+)\s+do\b/
              current_groups = Regexp.last_match(1).split(',').map { |g| g.strip.delete_prefix(':') }
            when 'end'
              current_groups = ['default']
            when /\Agem\s+['"]([^'"]+)['"]/
              groups_map[Regexp.last_match(1)] = current_groups
            end
          end

          groups_map
        end

        def filter_specs_by_include_gems(specs, include_list)
          return specs if include_list.empty?

          by_name = specs.to_h { |s| [s[:name], s] }
          keep = {}
          queue = include_list.dup

          until queue.empty?
            curr = queue.shift
            next if keep[curr]

            keep[curr] = true
            spec = by_name[curr]
            next unless spec

            Array(spec[:dependencies]).each do |dep_name|
              queue << dep_name unless keep[dep_name]
            end
          end

          specs.select { |s| keep[s[:name]] }
        end

        def add_missing_included_gems(selected_specs, include_list)
          present = selected_specs.to_h { |s| [s[:name], true] }
          include_list.each do |name|
            next if present[name]

            ver = resolve_installed_gem_version(name) || 'unknown'
            selected_specs << {
              name: name,
              version: ver,
              dependencies: resolve_installed_gem_deps(name, ver)
            }
          end
        end

        def inspect_existing_layer_zip(layer)
          data = {
            gem_sizes: {},
            gem_versions: {},
            gem_licenses: {},
            gem_deps: {},
            total_size: nil
          }
          return data unless defined?(Zip::File) && Zip::File.respond_to?(:open)

          candidates = [
            File.join(@source_dir, 'build', 'artifacts', 'layers', "#{layer.name}.zip"),
            File.join(@source_dir, '.veltrunode', 'build', 'artifacts', 'layers', "#{layer.name}.zip")
          ]
          zip_path = candidates.find { |p| File.file?(p) }
          return data unless zip_path

          total_uncompressed = 0
          Zip::File.open(zip_path) do |zip|
            zip.each do |entry|
              next if entry.directory?

              total_uncompressed += entry.size
              next unless entry.name =~ %r{ruby/(?:gems/)?\d+\.\d+\.\d+/gems/([^/]+)/}

              full_name = Regexp.last_match(1)
              data[:gem_sizes][full_name] = (data[:gem_sizes][full_name] || 0) + entry.size
              data[:gem_versions][Regexp.last_match(1)] ||= Regexp.last_match(2) if full_name =~ /\A(.+)-(\d[^-]*)\z/
            end
          end
          data[:total_size] = total_uncompressed
          data
        rescue StandardError
          data
        end

        def resolve_gem_size(name, version)
          cache_key = "#{name}:#{version}"
          return @size_cache[cache_key] if @size_cache.key?(cache_key)

          dir = find_gem_directory(name, version)
          if dir && File.directory?(dir)
            total = Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH)
                       .select { |f| File.file?(f) }
                       .sum { |f| File.size(f) }
            return @size_cache[cache_key] = total
          end

          cached_gem = File.join(@source_dir, 'vendor', 'cache', "#{name}-#{version}.gem")
          return @size_cache[cache_key] = File.size(cached_gem) if File.file?(cached_gem)

          @size_cache[cache_key] = 0
        rescue StandardError
          @size_cache[cache_key] = 0
        end

        def find_gem_directory(name, version)
          patterns = [
            File.join(@source_dir, 'vendor', 'bundle', 'ruby', '*', 'gems', "#{name}-#{version}"),
            File.join(@source_dir, 'vendor', 'prebuilt', 'ruby', '*', 'gems', "#{name}-#{version}"),
            File.join(@source_dir, 'gems', "#{name}-#{version}")
          ]
          patterns.each do |pat|
            match = Dir.glob(pat).find { |d| File.directory?(d) }
            return match if match
          end

          if defined?(Gem::Specification)
            specs = Gem::Specification.find_all_by_name(name, "= #{version}")
            specs = Gem::Specification.find_all_by_name(name) if specs.empty?
            full_path = specs.first&.full_gem_path
            return full_path if full_path && File.directory?(full_path)
          end

          nil
        rescue StandardError
          nil
        end

        def resolve_gem_license(layer, name, version)
          if layer.respond_to?(:license_metadata)
            meta = layer.license_metadata
            if meta.is_a?(Hash)
              explicit = meta[name] || meta[name.to_sym]
              return explicit.to_s if explicit && !explicit.to_s.strip.empty?
            end
          end

          cache_key = "#{name}:#{version}"
          if @license_cache.key?(cache_key)
            cached = @license_cache[cache_key]
            has_str_meta = layer.respond_to?(:license_metadata) && layer.license_metadata.is_a?(String)
            return cached unless cached == 'UNKNOWN' && has_str_meta
          end

          gemspec_lic = read_license_from_local_gemspec(name, version)
          return @license_cache[cache_key] = gemspec_lic if gemspec_lic

          if defined?(Gem::Specification)
            specs = version && version != 'unknown' ? Gem::Specification.find_all_by_name(name, "= #{version}") : []
            specs = Gem::Specification.find_all_by_name(name) if specs.empty?
            if (spec = specs.first)
              lics = Array(spec.licenses || spec.license).compact.map(&:to_s).reject(&:empty?)
              return @license_cache[cache_key] = lics.join(', ') if lics.any?
            end
          end

          if layer.respond_to?(:license_metadata) && layer.license_metadata.is_a?(String) &&
             !layer.license_metadata.strip.empty?
            return layer.license_metadata.strip
          end

          @license_cache[cache_key] = 'UNKNOWN'
        rescue StandardError
          'UNKNOWN'
        end

        def read_license_from_local_gemspec(name, version)
          patterns = [
            File.join(@source_dir, 'vendor', 'bundle', 'ruby', '*', 'specifications', "#{name}-#{version}.gemspec"),
            File.join(@source_dir, 'specifications', "#{name}-#{version}.gemspec")
          ]
          patterns.each do |pat|
            file = Dir.glob(pat).find { |f| File.file?(f) }
            next unless file

            content = File.read(file)
            if content =~ /\.licenses?\s*=\s*\[([^\]]+)\]/
              lics = Regexp.last_match(1).scan(/['"]([^'"]+)['"]/).flatten
              return lics.join(', ') if lics.any?
            elsif content =~ /\.license\s*=\s*['"]([^'"]+)['"]/
              return Regexp.last_match(1)
            end
          end
          nil
        rescue StandardError
          nil
        end

        def resolve_installed_gem_version(name)
          patterns = [
            File.join(@source_dir, 'vendor', 'bundle', 'ruby', '*', 'gems', "#{name}-*"),
            File.join(@source_dir, 'gems', "#{name}-*")
          ]
          patterns.each do |pat|
            match = Dir.glob(pat).find { |d| File.directory?(d) }
            return Regexp.last_match(1) if match && File.basename(match) =~ /\A#{Regexp.escape(name)}-(.+)\z/
          end

          if defined?(Gem::Specification)
            spec = Gem::Specification.find_all_by_name(name).first
            return spec.version.to_s if spec
          end

          nil
        rescue StandardError
          nil
        end

        def resolve_installed_gem_deps(name, version)
          return [] unless defined?(Gem::Specification)

          specs = version && version != 'unknown' ? Gem::Specification.find_all_by_name(name, "= #{version}") : []
          specs = Gem::Specification.find_all_by_name(name) if specs.empty?
          spec = specs.first
          return [] unless spec

          spec.runtime_dependencies.map { |d| d.name.to_s }
        rescue StandardError
          []
        end

        def detect_conflicts(raw_layers_map)
          gem_occurrences = Hash.new { |h, k| h[k] = [] }

          raw_layers_map.each do |layer_name, info|
            info[:gems].each do |gem_node|
              gem_occurrences[gem_node.name] << {
                'layer_name' => layer_name,
                'version' => gem_node.version
              }
            end
          end

          conflicts = []
          gem_occurrences.keys.sort.each do |gem_name|
            layers_list = gem_occurrences[gem_name]
            next if layers_list.size < 2

            versions = layers_list.map { |l| l['version'] }.uniq
            conflict_type = versions.size > 1 ? 'version_mismatch' : 'duplicate'
            layer_names = layers_list.map { |l| l['layer_name'] }

            matching_fns = Array(@application.functions).select do |fn|
              fn_layers = Array(fn.layers).map(&:to_s)
              (fn_layers & layer_names).size >= 2
            end
            affected_fns = matching_fns.map { |fn| extract_fn_name(fn) }

            conflict_entry = {
              'gem_name' => gem_name,
              'conflict_type' => conflict_type,
              'layers' => layers_list,
              'affected_functions' => affected_fns
            }
            conflicts << conflict_entry

            layer_summary = layers_list.map { |l| "#{l['layer_name']} (#{l['version']})" }.join(', ')
            @diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-LAYER-CONFLICT-001',
              severity: :warning,
              summary: "Conflicting library '#{gem_name}' (#{conflict_type}) across layers: #{layer_summary}.",
              suggested_action: "Consolidate '#{gem_name}' into a single shared Layer to prevent load path shadowing.",
              evidence: conflict_entry
            )
          end

          conflicts
        end

        def annotate_layers_with_conflicts(raw_layers_map, conflicts)
          conflicts_by_gem = conflicts.to_h { |c| [c['gem_name'], c] }
          annotated_map = {}

          raw_layers_map.each do |layer_name, info|
            layer = info[:model]
            deps_map = info[:deps_map]

            annotated_flat = info[:gems].map do |gem_node|
              conflict = conflicts_by_gem[gem_node.name]
              if conflict
                others = conflict['layers'].reject { |l| l['layer_name'] == layer_name }
                gem_node.with_conflict(
                  conflict: true,
                  conflict_type: conflict['conflict_type'].to_sym,
                  conflicting_layers: others
                )
              else
                gem_node
              end
            end

            root_gems = build_gem_dependency_tree(annotated_flat, deps_map)
            total_size = info[:zip_total_size] || annotated_flat.sum(&:size_bytes)

            annotated_map[layer_name] = LayerNode.new(
              layer_name: layer.name,
              description: layer.respond_to?(:description) ? layer.description : nil,
              compatible_runtimes: layer.respond_to?(:compatible_runtimes) ? layer.compatible_runtimes : [],
              architectures: layer.respond_to?(:architectures) ? layer.architectures : [],
              total_size_bytes: total_size,
              gems: annotated_flat,
              root_gems: root_gems
            )
          end

          annotated_map
        end

        def build_gem_dependency_tree(flat_gems, deps_map)
          by_name = flat_gems.to_h { |g| [g.name, g] }
          child_names = {}

          deps_map.each do |parent_name, dep_names|
            next unless by_name.key?(parent_name)

            Array(dep_names).each do |dep_name|
              child_names[dep_name] = true if by_name.key?(dep_name) && dep_name != parent_name
            end
          end

          top_names = flat_gems.map(&:name).reject { |n| child_names[n] }
          top_names = flat_gems.map(&:name) if top_names.empty?

          top_names.map do |root_name|
            build_gem_tree_node(root_name, by_name, deps_map, visited: {})
          end
        end

        def build_gem_tree_node(gem_name, by_name, deps_map, visited:)
          base_node = by_name[gem_name]
          return nil unless base_node

          next_visited = visited.merge(gem_name => true)
          child_nodes = Array(deps_map[gem_name]).filter_map do |dep_name|
            next if next_visited[dep_name] || !by_name.key?(dep_name)

            build_gem_tree_node(dep_name, by_name, deps_map, visited: next_visited)
          end

          base_node.with_conflict(
            conflict: base_node.conflict?,
            conflict_type: base_node.conflict_type,
            conflicting_layers: base_node.conflicting_layers,
            dependencies: child_nodes
          )
        end

        def build_function_node(fn, annotated_layers_map)
          fn_name = extract_fn_name(fn)
          fn_layer_names = Array(fn.layers).map(&:to_s)
          fn_layers = fn_layer_names.filter_map { |ln| annotated_layers_map[ln] }

          fn_conflicts = detect_function_layer_conflicts(fn_layers)

          FunctionNode.new(
            function_name: fn_name,
            runtime: fn.respond_to?(:runtime) ? fn.runtime.to_s : '',
            architecture: fn.respond_to?(:architecture) ? fn.architecture.to_s : 'x86_64',
            layers: fn_layers,
            conflicts: fn_conflicts
          )
        end

        def detect_function_layer_conflicts(fn_layers)
          gem_map = Hash.new { |h, k| h[k] = [] }
          fn_layers.each do |ln|
            ln.gems.each do |gn|
              gem_map[gn.name] << { 'layer_name' => ln.layer_name, 'version' => gn.version }
            end
          end

          gem_map.filter_map do |gem_name, list|
            next if list.size < 2

            versions = list.map { |i| i['version'] }.uniq
            {
              'gem_name' => gem_name,
              'conflict_type' => versions.size > 1 ? 'version_mismatch' : 'duplicate',
              'layers' => list
            }
          end
        end

        def extract_fn_name(fn)
          if fn.respond_to?(:logical_name)
            fn.logical_name.to_s
          elsif fn.respond_to?(:name)
            fn.name.to_s
          else
            fn.to_s
          end
        end
      end
    end
  end
end
