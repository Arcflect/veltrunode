# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'
require_relative 'async_invoke_config'
require_relative 'efs_mount'
require_relative 'event_source'
require_relative 'function_url'

module Veltrunode
  module Model
    class Function
      attr_reader :handler, :runtime, :logical_name, :architecture, :memory, :timeout, :ephemeral_storage,
                  :environment, :vpc_reference, :layers, :mounts, :iam_capabilities, :concurrency, :logging,
                  :alarms, :subscription_filters, :tracing, :insights, :async_invoke, :event_sources, :function_url,
                  :image, :custom_runtime, :node_bundle

      alias efs_mounts mounts
      alias container_image image
      alias bundle_config node_bundle

      def initialize(
        positional_logical_name = nil,
        logical_name: nil,
        handler: nil,
        runtime: nil,
        architecture: :x86_64,
        memory: 128,
        timeout: 3,
        ephemeral_storage: 512,
        environment: {},
        vpc_reference: nil,
        layers: [],
        mounts: [],
        efs_mounts: nil,
        efs_mount: nil,
        mount: nil,
        iam_capabilities: [],
        concurrency: nil,
        logging: nil,
        alarms: [],
        subscription_filters: [],
        tracing: nil,
        insights: nil,
        async_invoke: nil,
        event_sources: [],
        rule: nil,
        rules: [],
        function_url: nil,
        image: nil,
        container_image: nil,
        custom_runtime: nil,
        cargo: nil,
        rust: nil,
        go: nil,
        binary: nil,
        bootstrap: nil,
        entry: nil,
        bundle: nil,
        esbuild: nil,
        bun: nil,
        sourcemap: nil,
        source_map: nil,
        minify: nil,
        external: nil
      )
        name_val = positional_logical_name || logical_name
        validate_logical_name!(name_val)

        @logical_name = name_val.to_s.freeze
        @custom_runtime = normalize_custom_runtime(
          custom_runtime,
          cargo: cargo || rust,
          go: go,
          binary: binary,
          bootstrap: bootstrap
        )
        @node_bundle = normalize_node_bundle(
          bundle,
          entry: entry,
          esbuild: esbuild,
          bun: bun,
          sourcemap: sourcemap.nil? ? source_map : sourcemap,
          minify: minify,
          external: external
        )
        resolved_runtime = normalize_runtime(runtime)
        resolved_runtime ||= 'provided.al2023' if @custom_runtime
        resolved_runtime ||= 'nodejs20.x' if @node_bundle
        @runtime = resolved_runtime&.freeze
        resolved_handler = handler&.to_s
        if resolved_handler.nil? || resolved_handler.strip.empty?
          if custom_runtime?
            resolved_handler = 'bootstrap'
          elsif node_bundle?
            resolved_handler = derive_default_node_bundle_handler
          end
        end
        @handler = resolved_handler&.freeze
        @architecture = normalize_architecture(architecture)
        @memory = memory.to_i
        @timeout = timeout.to_i
        @ephemeral_storage = ephemeral_storage.to_i
        @environment = freeze_hash(environment)
        @vpc_reference = freeze_value(vpc_reference)
        @layers = freeze_array(layers)
        @mounts = normalize_mounts_list(mounts, efs_mounts, efs_mount, mount)
        @iam_capabilities = freeze_array(iam_capabilities)
        @concurrency = freeze_value(concurrency)
        @logging = freeze_value(logging)
        @alarms = freeze_array(alarms)
        @subscription_filters = resolve_initial_subscription_filters(subscription_filters, logging)
        @tracing = normalize_tracing(tracing)
        @insights = normalize_insights(insights)
        @async_invoke = normalize_async_invoke(async_invoke)
        @event_sources = normalize_event_sources(event_sources, rule: rule, rules: rules)
        @function_url = normalize_function_url(function_url)
        @image = normalize_image(image.nil? ? container_image : image)

        freeze if @handler || @runtime || @image || @custom_runtime || @node_bundle
      end

      def handler=(h)
        @handler = h&.to_s&.freeze
      end

      def runtime=(r)
        @runtime = r&.to_s&.freeze
      end

      def tracing_mode
        tracing&.fetch('mode', nil)
      end

      def tracing_enabled?
        !tracing_mode.nil?
      end

      def active_tracing?
        tracing_mode == 'Active'
      end

      def pass_through_tracing?
        tracing_mode == 'PassThrough'
      end

      def adot_enabled?
        tracing ? (tracing['adot'] == true || tracing['adot'].is_a?(String)) : false
      end

      def adot_layer_arn
        tracing && tracing['adot'].is_a?(String) ? tracing['adot'] : nil
      end

      def insights_enabled?
        return false if insights.nil?

        insights['enabled'] == true
      end

      def insights_layer_arn
        insights&.fetch('layer_arn', nil)
      end

      def insights_version
        insights&.fetch('version', nil)
      end

      def async_invoke?
        !async_invoke.nil?
      end
      alias async_invoke_enabled? async_invoke?

      def event_sources?
        !@event_sources.empty?
      end

      def rules
        @event_sources.select(&:rule?)
      end

      def rule
        rules.first
      end

      def rules?
        !rules.empty?
      end

      def msk_event_sources
        @event_sources.select { |s| s.respond_to?(:msk?) && s.msk? }
      end

      def mq_event_sources
        @event_sources.select { |s| s.respond_to?(:mq?) && s.mq? }
      end

      def broker_event_sources
        @event_sources.select { |s| s.respond_to?(:broker?) && s.broker? }
      end

      def broker_event_sources?
        !broker_event_sources.empty?
      end

      def function_url?
        !@function_url.nil?
      end
      alias function_url_enabled? function_url?

      def image?
        !@image.nil? && !@image.empty?
      end
      alias container_image? image?

      def package_type
        image? ? 'Image' : 'Zip'
      end

      def arm64?
        @architecture == :arm64
      end

      def x86_64?
        @architecture == :x86_64
      end

      def custom_runtime?
        @runtime.to_s.start_with?('provided') || (!@custom_runtime.nil? && !@custom_runtime.empty?)
      end

      def cargo?
        @custom_runtime&.fetch('toolchain', nil) == 'cargo'
      end
      alias rust_runtime? cargo?

      def go?
        @custom_runtime&.fetch('toolchain', nil) == 'go'
      end
      alias go_runtime? go?

      def custom_runtime_toolchain
        @custom_runtime&.fetch('toolchain', nil)
      end

      def custom_runtime_target
        explicit = @custom_runtime&.fetch('target', nil)
        return explicit if explicit && !explicit.to_s.strip.empty?

        if cargo?
          arm64? ? 'aarch64-unknown-linux-musl' : 'x86_64-unknown-linux-musl'
        elsif go?
          arm64? ? 'linux/arm64' : 'linux/amd64'
        end
      end

      def go_arch
        arm64? ? 'arm64' : 'amd64'
      end

      def node_bundle?
        !@node_bundle.nil? && !@node_bundle.empty?
      end
      alias bundled_nodejs? node_bundle?

      def entry
        @node_bundle&.fetch('entry', nil)
      end

      def bundler
        @node_bundle&.fetch('bundler', nil)
      end

      def esbuild?
        node_bundle? && bundler == 'esbuild'
      end

      def bun?
        node_bundle? && bundler == 'bun'
      end

      def sourcemap
        @node_bundle&.fetch('sourcemap', nil)
      end
      alias source_map sourcemap

      def sourcemap?
        ![nil, false, 'false', 'none'].include?(sourcemap)
      end
      alias source_map? sourcemap?

      def bundle_outfile
        return nil unless node_bundle?

        explicit_out = @node_bundle['outfile']
        return explicit_out if explicit_out && !explicit_out.strip.empty?

        ext = @node_bundle['format'] == 'esm' ? '.mjs' : '.js'
        if @handler&.include?('.')
          mod_part = @handler.rpartition('.').first
          return "#{File.basename(mod_part)}#{ext}" unless mod_part.empty?
        end

        base = File.basename(entry.to_s).sub(/\.(?:[cm]?ts|tsx|[cm]?js|jsx)\z/i, '')
        base = 'index' if base.empty?
        "#{base}#{ext}"
      end

      def bundle_target
        return nil unless node_bundle?

        explicit_target = @node_bundle['target']
        return explicit_target if explicit_target && !explicit_target.strip.empty?

        if @runtime.to_s =~ /\Anode(?:js)?(\d+)/i
          "node#{Regexp.last_match(1)}"
        else
          'node20'
        end
      end

      def image_dockerfile
        @image&.fetch('dockerfile', nil)
      end

      def image_tag
        @image&.fetch('tag', nil)
      end

      def image_uri
        @image&.fetch('uri', nil)
      end

      def image_context
        @image&.fetch('context', nil)
      end

      def image_repository
        @image&.fetch('repository', nil)
      end

      def image_build_args
        @image&.fetch('build_args', nil) || {}.freeze
      end

      def image_target
        @image&.fetch('target', nil)
      end

      def image_config
        return nil unless image?

        cfg = {}
        cfg['Command'] = @image['command'] if @image['command'] && !@image['command'].empty?
        cfg['EntryPoint'] = @image['entry_point'] if @image['entry_point'] && !@image['entry_point'].empty?
        cfg['WorkingDirectory'] = @image['working_directory'] if @image['working_directory']
        cfg.empty? ? nil : cfg
      end

      def validate_invariants(context = {})
        diagnostics = []

        validate_timeout(diagnostics)
        validate_mount_paths(diagnostics, context)
        validate_layer_architecture_compatibility(context, diagnostics)
        validate_references(context, diagnostics)
        validate_environment_duplicates(context, diagnostics)
        validate_alarms(diagnostics)
        validate_subscription_filters(diagnostics)
        validate_tracing(diagnostics)
        validate_broker_event_sources(context, diagnostics)

        diagnostics.freeze
      end

      def validate_invariants!(context = {})
        diagnostics = validate_invariants(context)
        return if diagnostics.empty?

        first_diag = diagnostics.first
        raise ValidationError.new(first_diag.summary, diagnostics:)
      end

      def validate_unique_mount_paths!(mount_map: {})
        EfsMount.validate_unique_local_paths!(mounts, mount_map: mount_map)
      end

      private

      def normalize_mounts_list(*mount_sources)
        items = []
        mount_sources.each do |src|
          next if src.nil? || src == false

          if src.is_a?(Array)
            items.concat(src)
          else
            items << src
          end
        end
        freeze_array(items)
      end

      def validate_logical_name!(name)
        raise ValidationError, 'Function logical_name is required' if name.nil? || name.to_s.strip.empty?
      end

      def normalize_runtime(raw_runtime)
        return nil if raw_runtime.nil?

        str = raw_runtime.to_s.strip
        return nil if str.empty?

        case str.downcase
        when 'provided_al2023', 'provided.al2023', 'al2023', 'custom'
          'provided.al2023'
        when 'provided_al2', 'provided.al2', 'al2'
          'provided.al2'
        else
          str
        end
      end

      def normalize_custom_runtime(raw_custom, cargo: nil, go: nil, binary: nil, bootstrap: nil)
        source_val = raw_custom
        default_toolchain = nil

        if source_val.nil?
          if !cargo.nil? && cargo != false
            source_val = cargo
            default_toolchain = 'cargo'
          elsif !go.nil? && go != false
            source_val = go
            default_toolchain = 'go'
          elsif !binary.nil? && binary != false
            source_val = binary
            default_toolchain = 'prebuilt'
          elsif !bootstrap.nil? && bootstrap != false
            source_val = bootstrap
            default_toolchain = 'prebuilt'
          end
        end

        return nil if source_val.nil? || source_val == false

        cfg = case source_val
              when true
                { 'toolchain' => default_toolchain || 'cargo' }
              when Symbol
                normalize_custom_runtime_symbol(source_val, default_toolchain)
              when String
                normalize_custom_runtime_string(source_val, default_toolchain)
              when Hash
                normalize_custom_runtime_hash(source_val, default_toolchain)
              else
                raise ValidationError, "Invalid custom_runtime configuration: #{source_val.class}"
              end

        freeze_hash(cfg)
      end

      def normalize_custom_runtime_symbol(sym, default_toolchain)
        case sym.to_s.downcase
        when 'cargo', 'rust'
          { 'toolchain' => 'cargo' }
        when 'go', 'golang'
          { 'toolchain' => 'go' }
        else
          { 'toolchain' => default_toolchain || 'prebuilt', 'bin' => sym.to_s }
        end
      end

      def normalize_custom_runtime_string(str, default_toolchain)
        s = str.strip
        raise ValidationError, 'Custom runtime configuration string cannot be empty' if s.empty?

        case default_toolchain
        when 'cargo'
          if s.end_with?('Cargo.toml')
            { 'toolchain' => 'cargo', 'manifest_path' => s }
          else
            { 'toolchain' => 'cargo', 'bin' => s }
          end
        when 'go'
          { 'toolchain' => 'go', 'package' => s }
        else
          if s.end_with?('Cargo.toml') || %w[cargo rust].include?(s.downcase)
            res = { 'toolchain' => 'cargo' }
            res['manifest_path'] = s if s.end_with?('Cargo.toml')
            res
          elsif s.end_with?('.go') || %w[go golang].include?(s.downcase)
            res = { 'toolchain' => 'go' }
            res['package'] = s if s.end_with?('.go')
            res
          else
            { 'toolchain' => 'prebuilt', 'bootstrap_path' => s }
          end
        end
      end

      def normalize_custom_runtime_hash(raw, default_toolchain)
        tc_raw = raw[:toolchain] || raw['toolchain'] || default_toolchain
        tc = case tc_raw.to_s.strip.downcase
             when 'cargo', 'rust'
               'cargo'
             when 'go', 'golang'
               'go'
             when 'prebuilt', 'binary', 'bootstrap'
               'prebuilt'
             else
               infer_toolchain_from_hash(raw)
             end

        res = { 'toolchain' => tc }
        manifest = raw[:manifest_path] || raw['manifest_path'] || raw[:manifest] || raw['manifest']
        res['manifest_path'] = manifest.to_s.strip if manifest && !manifest.to_s.strip.empty?

        pkg = raw[:package] || raw['package'] || raw[:main] || raw['main']
        res['package'] = pkg.to_s.strip if pkg && !pkg.to_s.strip.empty?

        bin = raw[:bin] || raw['bin'] || raw[:binary] || raw['binary']
        res['bin'] = bin.to_s.strip if bin && !bin.to_s.strip.empty?

        bs_path = raw[:bootstrap_path] || raw['bootstrap_path'] || raw[:bootstrap] || raw['bootstrap'] ||
                  raw[:path] || raw['path']
        res['bootstrap_path'] = bs_path.to_s.strip if bs_path && !bs_path.to_s.strip.empty?

        target = raw[:target] || raw['target']
        res['target'] = target.to_s.strip if target && !target.to_s.strip.empty?

        docker_val = raw.key?(:docker) ? raw[:docker] : raw['docker']
        docker_val = raw[:container] if docker_val.nil? && raw.key?(:container)
        docker_val = raw['container'] if docker_val.nil? && raw.key?('container')
        res['docker'] = docker_val ? true : false unless docker_val.nil?

        img = raw[:image] || raw['image'] || raw[:build_image] || raw['build_image']
        res['image'] = img.to_s.strip if img && !img.to_s.strip.empty?

        rel_val = raw.key?(:release) ? raw[:release] : raw['release']
        res['release'] = rel_val.nil? || (rel_val ? true : false)

        locked_val = raw.key?(:locked) ? raw[:locked] : raw['locked']
        res['locked'] = locked_val ? true : false unless locked_val.nil?

        cgo_val = raw.key?(:cgo) ? raw[:cgo] : raw['cgo']
        cgo_val = raw[:cgo_enabled] if cgo_val.nil? && raw.key?(:cgo_enabled)
        cgo_val = raw['cgo_enabled'] if cgo_val.nil? && raw.key?('cgo_enabled')
        res['cgo_enabled'] = cgo_val ? true : false unless cgo_val.nil?

        ldflags = raw[:ldflags] || raw['ldflags']
        res['ldflags'] = ldflags.to_s.strip if ldflags && !ldflags.to_s.strip.empty?

        tags = raw[:tags] || raw['tags']
        res['tags'] = Array(tags).flatten.map(&:to_s) if tags

        flags = raw[:build_flags] || raw['build_flags'] || raw[:flags] || raw['flags']
        res['build_flags'] = Array(flags).flatten.map(&:to_s) if flags

        env = raw[:env] || raw['env'] || raw[:environment] || raw['environment']
        res['env'] = env.transform_keys(&:to_s).transform_values(&:to_s) if env.is_a?(Hash) && !env.empty?

        res
      end

      def infer_toolchain_from_hash(raw)
        if raw.key?(:manifest_path) || raw.key?('manifest_path') || raw.key?(:manifest) || raw.key?('manifest') ||
           raw.key?(:bin) || raw.key?('bin') || raw.key?(:locked) || raw.key?('locked')
          'cargo'
        elsif raw.key?(:package) || raw.key?('package') || raw.key?(:ldflags) || raw.key?('ldflags') ||
              raw.key?(:cgo) || raw.key?('cgo') || raw.key?(:cgo_enabled) || raw.key?('cgo_enabled')
          'go'
        else
          'prebuilt'
        end
      end

      def derive_default_node_bundle_handler
        out = @node_bundle['outfile']
        mod = if out && !out.strip.empty?
                out.sub(/\.(?:[cm]?js)\z/i, '')
              else
                base = File.basename(@node_bundle['entry'].to_s).sub(/\.(?:[cm]?ts|tsx|[cm]?js|jsx)\z/i, '')
                base.empty? ? 'index' : base
              end
        export_name = @node_bundle['export_name'] || 'handler'
        "#{mod}.#{export_name}"
      end

      def normalize_node_bundle(raw_bundle, entry: nil, esbuild: nil, bun: nil, sourcemap: nil, minify: nil,
                                external: nil)
        has_any = !raw_bundle.nil? || !entry.nil? || !esbuild.nil? || !bun.nil? ||
                  !sourcemap.nil? || !minify.nil? || !external.nil?
        return nil unless has_any
        return nil if raw_bundle == false && entry.nil? && esbuild.nil? && bun.nil?

        base = {}
        if esbuild.is_a?(Hash)
          base.merge!(esbuild.transform_keys(&:to_sym))
          base[:bundler] ||= 'esbuild'
        elsif esbuild.is_a?(String)
          base[:entry] = esbuild
          base[:bundler] ||= 'esbuild'
        elsif esbuild
          base[:bundler] ||= 'esbuild'
        end

        if bun.is_a?(Hash)
          base.merge!(bun.transform_keys(&:to_sym))
          base[:bundler] = 'bun'
        elsif bun.is_a?(String)
          base[:entry] = bun
          base[:bundler] = 'bun'
        elsif bun
          base[:bundler] = 'bun'
        end

        case raw_bundle
        when Hash
          base.merge!(raw_bundle.transform_keys(&:to_sym))
        when String
          base[:entry] ||= raw_bundle
        when Symbol
          base[:bundler] = raw_bundle.to_s
        end

        base[:entry] = entry if entry
        base[:sourcemap] = sourcemap unless sourcemap.nil?
        base[:minify] = minify unless minify.nil?
        base[:external] = external unless external.nil?

        normalize_node_bundle_hash(base)
      end

      def normalize_node_bundle_hash(raw)
        entry_raw = (raw[:entry] || raw[:entry_point] || raw[:entrypoint]).to_s.strip
        if entry_raw.empty?
          raise ValidationError, "Function Node.js/TypeScript bundle configuration requires an 'entry' file path"
        end

        entry_file, export_name = split_entry_and_export(entry_raw)
        bundler_raw = (raw[:bundler] || 'esbuild').to_s.strip.downcase
        unless %w[esbuild bun].include?(bundler_raw)
          raise ValidationError, "Unsupported Node.js bundler '#{bundler_raw}'. Valid bundlers are :esbuild, :bun"
        end

        tree_shake = raw[:tree_shaking].nil? || (raw[:tree_shaking] ? true : false)
        res = {
          'entry' => entry_file,
          'bundler' => bundler_raw,
          'sourcemap' => normalize_sourcemap_option(raw.key?(:sourcemap) ? raw[:sourcemap] : raw[:source_map]),
          'minify' => raw[:minify] ? true : false,
          'tree_shaking' => tree_shake,
          'format' => normalize_bundle_format(raw[:format])
        }
        res['export_name'] = export_name if export_name
        res['target'] = raw[:target].to_s.strip if raw[:target] && !raw[:target].to_s.strip.empty?
        res['outfile'] = raw[:outfile].to_s.strip if raw[:outfile] && !raw[:outfile].to_s.strip.empty?
        res['tsconfig'] = raw[:tsconfig].to_s.strip if raw[:tsconfig] && !raw[:tsconfig].to_s.strip.empty?
        res['banner'] = raw[:banner].to_s if raw[:banner] && !raw[:banner].to_s.empty?

        ext_list = Array(raw[:external]).flatten.compact.map(&:to_s).reject(&:empty?)
        res['external'] = ext_list unless ext_list.empty?

        if raw[:define].is_a?(Hash) && !raw[:define].empty?
          res['define'] = raw[:define].transform_keys(&:to_s).transform_values(&:to_s)
        end

        flags = Array(raw[:build_flags] || raw[:flags]).flatten.compact.map(&:to_s)
        res['build_flags'] = flags unless flags.empty?

        freeze_hash(res)
      end

      def split_entry_and_export(entry_str)
        if entry_str.include?(':') && !entry_str.match?(%r{\A[a-zA-Z]:[\\/]})
          file_part, exp_part = entry_str.split(':', 2)
          [file_part.strip, exp_part.strip.empty? ? nil : exp_part.strip]
        else
          [entry_str, nil]
        end
      end

      def normalize_sourcemap_option(val)
        return false if val.nil? || val == false

        return true if val == true

        str = val.to_s.strip.downcase
        case str
        when 'true', 'yes', 'enabled'
          true
        when 'false', 'no', 'none', 'disabled', ''
          false
        when 'inline', 'external', 'linked', 'both'
          str
        else
          raise ValidationError,
                "Invalid sourcemap option '#{val}'. Valid options are true, false, :inline, :external, :linked, :both"
        end
      end

      def normalize_bundle_format(fmt)
        return 'cjs' if fmt.nil? || fmt.to_s.strip.empty?

        case fmt.to_s.strip.downcase
        when 'cjs', 'commonjs'
          'cjs'
        when 'esm', 'module'
          'esm'
        else
          raise ValidationError, "Unsupported bundle format '#{fmt}'. Valid formats are :cjs, :esm"
        end
      end

      def normalize_image(raw_image)
        return nil if raw_image.nil? || raw_image == false

        if raw_image.is_a?(String)
          str = raw_image.strip
          raise ValidationError, 'Function image URI cannot be empty' if str.empty?

          return freeze_hash('uri' => str)
        end

        if (!raw_image.is_a?(Symbol) && raw_image.respond_to?(:name)) || raw_image.is_a?(Symbol)
          return freeze_hash('uri' => raw_image)
        end

        unless raw_image.is_a?(Hash)
          raise ValidationError,
                "Invalid function image configuration '#{raw_image}'. " \
                'Must be a Hash (e.g. { dockerfile: "./Dockerfile", tag: "..." }) or image URI String'
        end

        dockerfile = raw_image[:dockerfile] || raw_image['dockerfile'] ||
                     raw_image[:Dockerfile] || raw_image['Dockerfile']
        uri = raw_image[:uri] || raw_image['uri'] || raw_image[:image_uri] || raw_image['image_uri'] ||
              raw_image[:ImageUri] || raw_image['ImageUri']
        if (dockerfile.nil? || dockerfile.to_s.strip.empty?) && (uri.nil? || (uri.is_a?(String) && uri.strip.empty?))
          raise ValidationError, "Function image configuration requires either 'dockerfile' or 'uri'"
        end

        result = {}
        result['dockerfile'] = dockerfile.to_s.strip if dockerfile && !dockerfile.to_s.strip.empty?
        if uri
          result['uri'] = uri.is_a?(String) ? uri.strip : uri
        end
        ctx = raw_image[:context] || raw_image['context']
        result['context'] = (ctx && !ctx.to_s.strip.empty? ? ctx.to_s.strip : '.') if result['dockerfile']
        tag = raw_image[:tag] || raw_image['tag']
        result['tag'] = (tag && !tag.to_s.strip.empty? ? tag.to_s.strip : 'latest') if result['dockerfile'] || tag
        repo = raw_image[:repository] || raw_image['repository']
        result['repository'] = repo.to_s.strip if repo && !repo.to_s.strip.empty?
        build_args = raw_image[:build_args] || raw_image['build_args']
        if build_args.is_a?(Hash) && !build_args.empty?
          result['build_args'] = build_args.transform_keys(&:to_s).transform_values(&:to_s)
        end
        target = raw_image[:target] || raw_image['target']
        result['target'] = target.to_s.strip if target && !target.to_s.strip.empty?

        cmd = raw_image[:command] || raw_image['command'] || raw_image[:Command] || raw_image['Command']
        result['command'] = Array(cmd).flatten.map(&:to_s) if cmd
        ep = raw_image[:entry_point] || raw_image['entry_point'] ||
             raw_image[:entrypoint] || raw_image['entrypoint'] ||
             raw_image[:EntryPoint] || raw_image['EntryPoint']
        result['entry_point'] = Array(ep).flatten.map(&:to_s) if ep
        wd = raw_image[:working_directory] || raw_image['working_directory'] ||
             raw_image[:workdir] || raw_image['workdir'] ||
             raw_image[:WorkingDirectory] || raw_image['WorkingDirectory']
        result['working_directory'] = wd.to_s.strip if wd && !wd.to_s.strip.empty?

        freeze_hash(result)
      end

      def normalize_architecture(arch)
        return :x86_64 if arch.nil?

        case arch.to_s.strip.downcase
        when 'arm64', 'aarch64'
          :arm64
        when 'x86_64', 'amd64'
          :x86_64
        else
          arch.to_s.to_sym.freeze
        end
      end

      def freeze_value(val)
        case val
        when Hash
          freeze_hash(val)
        when Array
          freeze_array(val)
        when String
          val.dup.freeze
        else
          val.frozen? ? val : val.freeze
        end
      end

      def freeze_hash(hash)
        return {}.freeze if hash.nil?

        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = freeze_value(v)
        end.freeze
      end

      def freeze_array(array)
        return [].freeze if array.nil?

        array.map { |item| freeze_value(item) }.freeze
      end

      def validate_timeout(diagnostics)
        return if (1..900).cover?(timeout)

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-TIMEOUT',
          severity: :error,
          summary: "Function '#{logical_name}' timeout (#{timeout}s) is outside the valid range of 1 to 900 seconds.",
          suggested_action: 'Specify a timeout value between 1 and 900 seconds.',
          evidence: { 'timeout' => timeout, 'valid_range' => [1, 900] }
        )
      end

      def validate_mount_paths(diagnostics, context = {})
        mounts.each do |m|
          path = extract_mount_path(m)
          next if path.nil? || path.start_with?('/mnt/')

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-PATH',
            severity: :error,
            summary: "Mount path '#{path}' in function '#{logical_name}' must start with '/mnt/'.",
            suggested_action: "Ensure the EFS mount local path starts with '/mnt/'.",
            evidence: { 'local_path' => path }
          )
        end

        available_mounts = context[:available_mounts] || context[:mounts] || []
        duplicates = EfsMount.duplicate_local_paths(mounts, mount_map: available_mounts)
        duplicates.each do |dup_path|
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-DUPLICATE-PATH',
            severity: :error,
            summary: "Duplicate EFS mount local_path '#{dup_path}' in function '#{logical_name}'.",
            suggested_action: "Specify a unique local_path (e.g., '/mnt/data', '/mnt/shared') " \
                              "for each EFS mount in function '#{logical_name}'.",
            evidence: {
              'function' => logical_name,
              'local_path' => dup_path,
              'duplicate_local_path' => dup_path
            }
          )
        end
      end

      def extract_mount_path(mount)
        if mount.is_a?(Hash)
          mount[:local_path] || mount['local_path'] ||
            mount[:local_mount_path] || mount['local_mount_path'] || mount['LocalMountPath']
        elsif mount.respond_to?(:local_path)
          mount.local_path
        elsif mount.is_a?(String) && mount.include?(':')
          mount.split(':', 2).last
        elsif mount.is_a?(String) && mount.start_with?('/')
          mount
        end
      end

      def validate_layer_architecture_compatibility(context, diagnostics)
        available_layers = context[:available_layers] || context[:layers] || []
        return if available_layers.empty?

        layers.each do |layer_ref|
          layer_obj = find_by_name(available_layers, extract_name(layer_ref))
          next unless layer_obj

          layer_archs = extract_architectures(layer_obj)
          next if layer_archs.nil? || layer_archs.empty?
          next if layer_archs.map(&:to_sym).include?(architecture)

          l_name = extract_name(layer_ref)
          arch_str = layer_archs.join(', ')
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-LAYER-001',
            severity: :error,
            summary: "Layer '#{l_name}' architectures (#{arch_str}) are incompatible " \
                     "with function '#{logical_name}' architecture (#{architecture}).",
            suggested_action: 'Attach a layer built for the function architecture ' \
                              'or change the function architecture.',
            evidence: {
              'function_architecture' => architecture.to_s,
              'layer_architectures' => layer_archs.map(&:to_s)
            }
          )
        end
      end

      def validate_references(context, diagnostics)
        available_layer_names = fetch_known_names(context, :available_layer_names, :available_layers, :layers)
        if available_layer_names
          layers.each do |l_ref|
            l_name = extract_name(l_ref)
            next if available_layer_names.include?(l_name)

            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-REF-001',
              severity: :error,
              summary: "Referenced layer '#{l_name}' in function '#{logical_name}' does not exist.",
              suggested_action: 'Ensure the referenced layer is defined in the application.',
              evidence: { 'missing_layer' => l_name }
            )
          end
        end

        available_mount_names = fetch_known_names(context, :available_mount_names, :available_mounts, :mounts)
        return unless available_mount_names

        mounts.each do |m_ref|
          m_name = extract_name(m_ref)
          next if m_name.nil? && direct_mount_arn?(m_ref)
          next if available_mount_names.include?(m_name)

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-REF-001',
            severity: :error,
            summary: "Referenced mount '#{m_name}' in function '#{logical_name}' does not exist.",
            suggested_action: 'Ensure the referenced mount is defined in the application.',
            evidence: { 'missing_mount' => m_name }
          )
        end
      end

      def direct_mount_arn?(mount)
        return false unless mount.is_a?(Hash)

        !(mount[:arn] || mount['arn'] || mount['Arn'] ||
          mount[:access_point_source] || mount['access_point_source']).nil?
      end

      def validate_environment_duplicates(context, diagnostics)
        conflicts = []
        conflicts.concat(Array(context[:duplicate_env_keys])) if context[:duplicate_env_keys]

        stage_env = context[:stage_environment]
        if stage_env.is_a?(Hash)
          dup_keys = environment.keys.map(&:to_s) & stage_env.keys.map(&:to_s)
          conflicts.concat(dup_keys)
        end

        conflicts.uniq.each do |key|
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-DSL-ENV',
            severity: :error,
            summary: "Duplicate environment key '#{key}' found after stage merge in function '#{logical_name}'.",
            suggested_action: 'Remove duplicate environment variable definitions across stages.',
            evidence: { 'duplicate_key' => key }
          )
        end
      end

      def fetch_known_names(context, names_key, objs_key, alt_objs_key)
        if context.key?(names_key)
          Array(context[names_key]).map(&:to_s)
        elsif context.key?(objs_key)
          extract_names_from_collection(context[objs_key])
        elsif context.key?(alt_objs_key)
          extract_names_from_collection(context[alt_objs_key])
        end
      end

      def extract_names_from_collection(collection)
        case collection
        when Hash
          collection.keys.map(&:to_s)
        when Array
          collection.map { |item| extract_name(item) }.compact
        end
      end

      def extract_name(item)
        value =
          if item.is_a?(Hash)
            item[:name] || item['name'] || item[:logical_name] || item['logical_name'] ||
              item[:symbolic_name] || item['symbolic_name'] || item[:mount] || item['mount']
          elsif item.respond_to?(:logical_name)
            item.logical_name
          elsif item.respond_to?(:name)
            item.name
          elsif item.respond_to?(:symbolic_name)
            item.symbolic_name
          elsif item.is_a?(String) && item.include?(':')
            item.split(':', 2).first
          else
            item
          end
        value&.to_s
      end

      def find_by_name(collection, name)
        return nil if name.nil?

        if collection.is_a?(Hash)
          collection[name] || collection[name.to_sym]
        elsif collection.is_a?(Array)
          collection.find { |item| extract_name(item) == name }
        end
      end

      def extract_architectures(layer_obj)
        if layer_obj.is_a?(Hash)
          layer_obj[:architectures] || layer_obj['architectures'] ||
            layer_obj[:compatible_architectures] || layer_obj['compatible_architectures']
        elsif layer_obj.respond_to?(:architectures)
          layer_obj.architectures
        elsif layer_obj.respond_to?(:compatible_architectures)
          layer_obj.compatible_architectures
        end
      end

      def validate_alarms(diagnostics)
        Array(@alarms).each do |alarm|
          alarm.validate! if alarm.respond_to?(:validate!)
        rescue ValidationError => e
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-ALARM-001',
            severity: :error,
            summary: "Invalid alarm in function '#{logical_name}': #{e.message}",
            suggested_action: 'Check alarm metric, threshold, and evaluation parameters.',
            evidence: { 'function' => logical_name, 'error' => e.message }
          )
        end
      end

      def resolve_initial_subscription_filters(filters, logging_cfg)
        list = Array(filters).compact

        if list.empty? && logging_cfg.is_a?(Hash)
          raw = logging_cfg[:subscription_filters] || logging_cfg['subscription_filters'] ||
                logging_cfg[:subscription_filter] || logging_cfg['subscription_filter']
          if raw.is_a?(Array)
            list = raw
          elsif raw.is_a?(Hash)
            list = [raw]
          end
        end

        freeze_array(list)
      end

      def validate_subscription_filters(diagnostics)
        Array(@subscription_filters).each do |filter|
          filter.validate! if filter.respond_to?(:validate!)
        rescue ValidationError => e
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-LOGS-001',
            severity: :error,
            summary: "Invalid subscription filter in function '#{logical_name}': #{e.message}",
            suggested_action: 'Check subscription filter destination and parameters.',
            evidence: { 'function' => logical_name, 'error' => e.message }
          )
        end
      end

      def normalize_tracing(val)
        return nil if val.nil? || val == false || val.to_s.downcase == 'disabled'

        if val.is_a?(Symbol) || val.is_a?(String)
          normalize_tracing_string(val)
        elsif val.is_a?(Hash)
          normalize_tracing_hash(val)
        else
          raise ValidationError, "Invalid tracing configuration: #{val.class}"
        end
      end

      def normalize_tracing_string(val)
        case val.to_s.downcase
        when 'active'
          { 'mode' => 'Active', 'adot' => false }.freeze
        when 'pass_through', 'passthrough'
          { 'mode' => 'PassThrough', 'adot' => false }.freeze
        when 'adot'
          { 'mode' => 'Active', 'adot' => true }.freeze
        else
          raise ValidationError, "Unsupported tracing mode: #{val}. Valid modes are :active, :pass_through, :adot"
        end
      end

      def normalize_tracing_hash(val)
        mode_raw = val[:mode] || val['mode'] || val[:Mode] || val['Mode']
        adot_raw = val[:adot] || val['adot'] || val[:Adot] || val['Adot']

        mode_str = (mode_raw || (adot_raw ? 'active' : nil)).to_s.downcase
        mode = case mode_str
               when 'active', ''
                 'Active'
               when 'pass_through', 'passthrough'
                 'PassThrough'
               else
                 raise ValidationError, "Unsupported tracing mode: #{mode_raw}. Valid modes are :active, :pass_through"
               end

        adot = if adot_raw.is_a?(String) && !adot_raw.strip.empty?
                 adot_raw.strip.freeze
               elsif adot_raw
                 true
               else
                 false
               end

        { 'mode' => mode, 'adot' => adot }.freeze
      end

      def validate_tracing(diagnostics)
        return unless @tracing

        mode = tracing_mode
        return if %w[Active PassThrough].include?(mode)

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-TRACING-001',
          severity: :error,
          summary: "Invalid tracing mode '#{mode}' in function '#{logical_name}'.",
          suggested_action: 'Specify :active or :pass_through for tracing.',
          evidence: { 'function' => logical_name, 'tracing' => @tracing }
        )
      end

      def normalize_insights(val)
        return nil if val.nil? || val == false

        case val
        when true
          { 'enabled' => true }.freeze
        when String
          str = val.strip
          raise ValidationError, 'Insights configuration cannot be blank' if str.empty?

          { 'enabled' => true, 'layer_arn' => str.freeze }.freeze
        when Numeric
          raise ValidationError, "Invalid insights version: #{val}" unless val.positive?

          { 'enabled' => true, 'version' => val.to_i }.freeze
        when Hash
          enabled_val = val[:enabled].nil? && val['enabled'].nil? ? true : (val[:enabled] || val['enabled'])
          return nil unless enabled_val

          arn = val[:layer_arn] || val['layer_arn']
          ver = val[:version] || val['version']

          res = { 'enabled' => true }
          res['layer_arn'] = arn.to_s.strip.freeze if arn && !arn.to_s.strip.empty?
          res['version'] = ver.to_i if ver
          res.freeze
        else
          raise ValidationError, "Invalid insights configuration: #{val.class}"
        end
      end

      def normalize_async_invoke(val)
        return nil if val.nil? || val == false
        return val if val.is_a?(AsyncInvokeConfig)

        raise ValidationError, "Invalid async_invoke configuration: #{val.class}" unless val.is_a?(Hash)
        return nil if val[:enabled] == false || val['enabled'] == false

        cleaned = val.reject { |k, _| k.to_s == 'enabled' }
        kwargs = cleaned.each_with_object({}) do |(k, v), memo|
          memo[k.to_sym] = v
        end
        AsyncInvokeConfig.new(**kwargs)
      end

      def normalize_event_sources(sources, rule: nil, rules: [])
        base_list = if sources.nil? || sources == false
                      []
                    else
                      sources.is_a?(Array) ? sources.dup : [sources]
                    end

        rule_items = []
        rule_items << rule if rule && rule != false
        if rules && rules != false
          rule_items.concat(rules.is_a?(Array) ? rules : [rules])
        end

        rule_items.each do |r|
          base_list << (r.is_a?(EventSource) ? r : { rule: r })
        end

        return [].freeze if base_list.empty?

        normalized = base_list.map do |src|
          if src.is_a?(EventSource)
            src
          elsif src.is_a?(Hash)
            kwargs = src.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = v }
            EventSource.new(**kwargs)
          else
            raise ValidationError, "Invalid event_source configuration: #{src.class}"
          end
        end
        normalized.freeze
      end

      def normalize_function_url(val)
        FunctionUrl.from(val)
      rescue ArgumentError => e
        raise ValidationError, e.message
      end

      def validate_broker_event_sources(context, diagnostics)
        brokers = broker_event_sources
        return if brokers.empty?

        brokers.each do |src|
          validate_broker_secret(src, diagnostics)
          validate_broker_source_vpc(src, diagnostics)
        end

        validate_function_broker_vpc(context, diagnostics) if @vpc_reference
      end

      def validate_broker_secret(src, diagnostics)
        has_sac_auth = Array(src.source_access_configurations).any? do |c|
          %w[BASIC_AUTH SASL_SCRAM_512_AUTH SASL_SCRAM_256_AUTH CLIENT_CERTIFICATE_TLS_AUTH].include?(c['Type'])
        end

        if src.mq? && src.secret.nil? && !has_sac_auth
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-IAM-003',
            severity: :error,
            summary: "Function '#{logical_name}' has an Amazon MQ event source without a Secrets Manager " \
                     'authentication secret configured.',
            suggested_action: "Specify 'secret' (Secrets Manager ARN or ref) on the MQ event source.",
            evidence: { 'function' => logical_name, 'event_source_type' => 'mq' }
          )
        end

        return unless src.secret.is_a?(String) && src.secret.start_with?('arn:')
        return if src.secret.match?(/\Aarn:aws[a-z-]*:secretsmanager:/)

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-IAM-003',
          severity: :error,
          summary: "Function '#{logical_name}' broker event source (#{src.type}) specifies an invalid " \
                   "Secrets Manager secret ARN '#{src.secret}'.",
          suggested_action: 'Provide a valid Secrets Manager ARN (arn:aws:secretsmanager:...) or parameter reference.',
          evidence: { 'function' => logical_name, 'secret' => src.secret }
        )
      end

      def validate_broker_source_vpc(src, diagnostics)
        has_sg = src.security_group_ids && !src.security_group_ids.empty?
        has_sub = src.subnet_ids && !src.subnet_ids.empty?
        return if (has_sg && has_sub) || (!has_sg && !has_sub)

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-VPC-001',
          severity: :error,
          summary: "Function '#{logical_name}' broker event source (#{src.type}) specifies partial VPC network " \
                   'configuration: both subnet_ids and security_group_ids must be provided together.',
          suggested_action: 'Specify both subnet_ids and security_group_ids for the broker event source.',
          evidence: {
            'function' => logical_name,
            'event_source_type' => src.type.to_s,
            'has_security_group_ids' => !has_sg.nil? && has_sg,
            'has_subnet_ids' => !has_sub.nil? && has_sub
          }
        )
      end

      def validate_function_broker_vpc(context, diagnostics)
        unless @vpc_reference.is_a?(Hash)
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-DSL-VPC-001',
            severity: :error,
            summary: "Function '#{logical_name}' has a broker event source with invalid vpc_reference: " \
                     'both subnet_ids and security_group_ids are required for VPC broker connectivity.',
            suggested_action: 'Configure vpc_reference with subnet_ids and security_group_ids.',
            evidence: { 'function' => logical_name }
          )
          return
        end

        sub_ids = @vpc_reference['subnet_ids'] || @vpc_reference['subnets'] || @vpc_reference['SubnetIds']
        sg_ids = @vpc_reference['security_group_ids'] || @vpc_reference['security_groups'] ||
                 @vpc_reference['security_group'] || @vpc_reference['SecurityGroupIds']
        available_sgs = fetch_known_names(
          context, :available_security_group_names, :available_security_groups, :security_groups
        )

        has_subs = sub_ids.is_a?(Hash) || !Array(sub_ids).compact.empty?
        has_sgs = sg_ids.is_a?(Hash) || !Array(sg_ids).compact.empty? || (available_sgs && !available_sgs.empty?)

        unless has_subs && has_sgs
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-DSL-VPC-001',
            severity: :error,
            summary: "Function '#{logical_name}' has a broker event source with incomplete VPC configuration: " \
                     'both subnet_ids and security_group_ids are required for VPC broker connectivity.',
            suggested_action: 'Configure both subnet_ids and security_group_ids in vpc_reference.',
            evidence: { 'function' => logical_name }
          )
        end

        return unless available_sgs && sg_ids && !sg_ids.is_a?(Hash)

        Array(sg_ids).each do |sg_ref|
          next if sg_ref.is_a?(Hash) || (!sg_ref.is_a?(Symbol) && sg_ref.respond_to?(:name))

          sg_str = sg_ref.to_s.strip
          next if sg_str.start_with?('sg-') || sg_str.end_with?('SecurityGroup')
          next if available_sgs.include?(sg_str)

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-REF-001',
            severity: :error,
            summary: "Referenced security group '#{sg_str}' in function '#{logical_name}' does not exist.",
            suggested_action: 'Ensure the referenced security group helper is defined in the application.',
            evidence: { 'function' => logical_name, 'missing_security_group' => sg_str }
          )
        end
      end
    end
  end
end
