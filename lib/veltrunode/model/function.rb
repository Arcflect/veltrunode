# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'
require_relative 'async_invoke_config'

module Veltrunode
  module Model
    class Function
      attr_reader :handler, :runtime, :logical_name, :architecture, :memory, :timeout, :ephemeral_storage,
                  :environment, :vpc_reference, :layers, :mounts, :iam_capabilities, :concurrency, :logging,
                  :alarms, :subscription_filters, :tracing, :insights, :async_invoke

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
        iam_capabilities: [],
        concurrency: nil,
        logging: nil,
        alarms: [],
        subscription_filters: [],
        tracing: nil,
        insights: nil,
        async_invoke: nil
      )
        name_val = positional_logical_name || logical_name
        validate_logical_name!(name_val)

        @logical_name = name_val.to_s.freeze
        @handler = handler&.to_s&.freeze
        @runtime = runtime&.to_s&.freeze
        @architecture = normalize_architecture(architecture)
        @memory = memory.to_i
        @timeout = timeout.to_i
        @ephemeral_storage = ephemeral_storage.to_i
        @environment = freeze_hash(environment)
        @vpc_reference = freeze_value(vpc_reference)
        @layers = freeze_array(layers)
        @mounts = freeze_array(mounts)
        @iam_capabilities = freeze_array(iam_capabilities)
        @concurrency = freeze_value(concurrency)
        @logging = freeze_value(logging)
        @alarms = freeze_array(alarms)
        @subscription_filters = resolve_initial_subscription_filters(subscription_filters, logging)
        @tracing = normalize_tracing(tracing)
        @insights = normalize_insights(insights)
        @async_invoke = normalize_async_invoke(async_invoke)

        freeze if @handler || @runtime
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

      def validate_invariants(context = {})
        diagnostics = []

        validate_timeout(diagnostics)
        validate_mount_paths(diagnostics)
        validate_layer_architecture_compatibility(context, diagnostics)
        validate_references(context, diagnostics)
        validate_environment_duplicates(context, diagnostics)
        validate_alarms(diagnostics)
        validate_subscription_filters(diagnostics)
        validate_tracing(diagnostics)

        diagnostics.freeze
      end

      def validate_invariants!(context = {})
        diagnostics = validate_invariants(context)
        return if diagnostics.empty?

        first_diag = diagnostics.first
        raise ValidationError.new(first_diag.summary, diagnostics:)
      end

      private

      def validate_logical_name!(name)
        raise ValidationError, 'Function logical_name is required' if name.nil? || name.to_s.strip.empty?
      end

      def normalize_architecture(arch)
        return :x86_64 if arch.nil?

        arch.to_s.to_sym.freeze
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

      def validate_mount_paths(diagnostics)
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
      end

      def extract_mount_path(mount)
        if mount.is_a?(Hash)
          mount[:local_path] || mount['local_path']
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
              item[:symbolic_name] || item['symbolic_name']
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

        kwargs = val.each_with_object({}) do |(k, v), memo|
          memo[k.to_sym] = v
        end
        AsyncInvokeConfig.new(**kwargs)
      end
    end
  end
end
