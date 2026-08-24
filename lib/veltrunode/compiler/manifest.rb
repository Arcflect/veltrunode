# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative '../version'
require_relative '../model/capability_expander'

module Veltrunode
  module Compiler
    class Manifest
      MANIFEST_SCHEMA_VERSION = '1.0'

      class << self
        def build_data(application:, function_results: [], layer_results: [], built_at: Time.now.utc)
          new(
            application: application,
            function_results: function_results,
            layer_results: layer_results,
            built_at: built_at
          ).build_data
        end

        def to_h(application:, function_results: [], layer_results: [], built_at: Time.now.utc)
          new(
            application: application,
            function_results: function_results,
            layer_results: layer_results,
            built_at: built_at
          ).to_h
        end

        def to_json(application:, function_results: [], layer_results: [], built_at: Time.now.utc)
          new(
            application: application,
            function_results: function_results,
            layer_results: layer_results,
            built_at: built_at
          ).to_json
        end

        def generate(application:, output_path:, function_results: [], layer_results: [], built_at: Time.now.utc)
          new(
            application: application,
            function_results: function_results,
            layer_results: layer_results,
            built_at: built_at
          ).generate(output_path)
        end
      end

      def initialize(application:, function_results: [], layer_results: [], built_at: Time.now.utc)
        @application = application
        @function_results = Array(function_results)
        @layer_results = Array(layer_results)
        @built_at = built_at.is_a?(Time) ? built_at.utc : Time.parse(built_at.to_s).utc
      end

      def build_data
        {
          'manifest_schema_version' => MANIFEST_SCHEMA_VERSION,
          'schema_version' => MANIFEST_SCHEMA_VERSION,
          'compiler_version' => Veltrunode::VERSION,
          'built_at' => @built_at.iso8601,
          'application' => build_application_section,
          'functions' => build_functions_section,
          'layers' => build_layers_section,
          'schedules' => build_schedules_section,
          'iam_capabilities' => build_iam_capabilities_section
        }
      end

      def to_h
        deep_sort_keys(build_data)
      end

      def to_json(*_args)
        "#{JSON.pretty_generate(to_h)}\n"
      end

      def generate(output_path)
        content = to_json
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, content)
        to_h
      end

      def deep_sort_keys(obj)
        case obj
        when Hash
          obj.keys.sort.to_h do |k|
            [k, deep_sort_keys(obj[k])]
          end
        when Array
          obj.map { |v| deep_sort_keys(v) }
        else
          obj
        end
      end

      private

      def build_application_section
        return {} unless @application

        res = {}
        name_val = extract_val(@application, :name)
        region_val = extract_val(@application, :region)
        stage_val = extract_val(@application, :stage)
        account_val = extract_val(@application, :account_constraint)

        res['name'] = name_val if name_val
        res['region'] = region_val if region_val
        res['stage'] = stage_val if stage_val
        res['account_constraint'] = account_val if account_val
        res
      end

      def build_functions_section
        return {} unless @application&.functions

        results_map = @function_results.each_with_object({}) do |res, memo|
          memo[res.function_name.to_s] = res if res.respond_to?(:function_name)
        end

        @application.functions.each_with_object({}) do |fn, memo|
          fn_name = extract_name(fn)
          res = results_map[fn_name]

          fn_info = {
            'logical_name' => fn_name,
            'handler' => extract_val(fn, :handler),
            'runtime' => extract_val(fn, :runtime),
            'architecture' => extract_val(fn, :architecture)&.to_s,
            'memory' => extract_val(fn, :memory),
            'timeout' => extract_val(fn, :timeout),
            'ephemeral_storage' => extract_val(fn, :ephemeral_storage)
          }

          if res
            ch = extract_val(res, :content_hash) || extract_val(res, :sha256)
            sha = extract_val(res, :sha256)
            zip = extract_val(res, :zip_path)

            fn_info['content_hash'] = ch if ch
            fn_info['sha256'] = sha if sha
            fn_info['artifact_hash'] = sha if sha
            fn_info['zip_path'] = File.basename(zip) if zip
          end

          env = extract_val(fn, :environment)
          fn_info['environment'] = env if env && !env.empty?

          vpc_ref = extract_val(fn, :vpc_reference)
          fn_info['vpc_reference'] = vpc_ref if vpc_ref && !vpc_ref.empty?

          attached_layers = extract_val(fn, :layers)
          fn_info['layers'] = Array(attached_layers) if attached_layers && !attached_layers.empty?

          mount_list = extract_val(fn, :mounts)
          fn_info['mounts'] = Array(mount_list) if mount_list && !mount_list.empty?

          conc = extract_val(fn, :concurrency)
          fn_info['concurrency'] = conc if conc && !conc.empty?

          log_cfg = extract_val(fn, :logging)
          fn_info['logging'] = log_cfg if log_cfg && !log_cfg.empty?

          memo[fn_name] = fn_info
        end
      end

      def build_layers_section
        return {} unless @application.respond_to?(:layers) && @application.layers

        results_map = @layer_results.each_with_object({}) do |res, memo|
          memo[res.layer_name.to_s] = res if res.respond_to?(:layer_name)
        end

        @application.layers.each_with_object({}) do |layer, memo|
          layer_name = extract_name(layer)
          res = results_map[layer_name]

          runtimes = extract_val(layer, :compatible_runtimes) || extract_val(layer, :runtimes) || []
          architectures = extract_val(layer, :architectures) || []

          layer_info = {
            'name' => layer_name,
            'compatible_runtimes' => Array(runtimes).map(&:to_s),
            'architectures' => Array(architectures).map(&:to_s)
          }

          src_spec = extract_val(layer, :source_spec)
          layer_info['source_spec'] = src_spec if src_spec && !src_spec.empty?

          build_env = extract_val(layer, :build_environment)
          layer_info['build_environment'] = build_env if build_env && !build_env.empty?

          ret_policy = extract_val(layer, :retention_policy)
          layer_info['retention_policy'] = ret_policy if ret_policy && !ret_policy.empty?

          desc = extract_val(layer, :description)
          layer_info['description'] = desc if desc && !desc.to_s.empty?

          lic = extract_val(layer, :license_metadata)
          layer_info['license_metadata'] = lic if lic && !lic.to_s.empty?

          if res
            ch = extract_val(res, :content_hash) || extract_val(res, :sha256)
            sha = extract_val(res, :sha256)
            zip = extract_val(res, :zip_path)

            layer_info['content_hash'] = ch if ch
            layer_info['sha256'] = sha if sha
            layer_info['artifact_hash'] = sha if sha
            layer_info['zip_path'] = File.basename(zip) if zip
          end

          memo[layer_name] = layer_info
        end
      end

      def build_schedules_section
        return {} unless @application.respond_to?(:schedules) && @application.schedules

        @application.schedules.each_with_object({}) do |sch, memo|
          sch_name = extract_name(sch)

          sch_info = {
            'name' => sch_name,
            'target_function' => extract_val(sch, :target_function),
            'expression_type' => extract_val(sch, :expression_type)&.to_s,
            'expression' => extract_val(sch, :expression),
            'timezone' => extract_val(sch, :timezone),
            'state' => extract_val(sch, :state)&.to_s
          }

          flex = extract_val(sch, :flexible_window)
          sch_info['flexible_window'] = flex if flex
          retry_pol = extract_val(sch, :retry_policy)
          sch_info['retry_policy'] = retry_pol if retry_pol
          dlq_val = extract_val(sch, :dlq)
          sch_info['dlq'] = dlq_val if dlq_val

          memo[sch_name] = sch_info
        end
      end

      def build_iam_capabilities_section
        return {} unless @application.respond_to?(:functions) && @application.functions

        context = {
          stage: extract_val(@application, :stage) || 'dev',
          region: extract_val(@application, :region) || 'ap-northeast-1',
          account: extract_val(@application, :account_constraint)
        }

        @application.functions.each_with_object({}) do |fn, memo|
          fn_name = extract_name(fn)
          caps = extract_val(fn, :iam_capabilities) || []
          statements = Model::CapabilityExpander.expand_all(caps, context)
          memo[fn_name] = statements.map { |stmt| deep_stringify_keys(stmt) }
        end
      end

      def extract_name(item)
        if item.respond_to?(:logical_name)
          item.logical_name
        elsif item.respond_to?(:name)
          item.name
        else
          item.to_s
        end
      end

      def extract_val(item, method_name)
        return nil unless item.respond_to?(method_name)

        val = item.public_send(method_name)
        deep_stringify_keys(val)
      end

      def deep_stringify_keys(obj)
        return '[FILTERED]' if obj.respond_to?(:secret?) && obj.secret?

        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = deep_stringify_keys(v)
          end
        when Array
          obj.map { |v| deep_stringify_keys(v) }
        when Symbol
          obj.to_s
        else
          obj
        end
      end
    end
  end
end
