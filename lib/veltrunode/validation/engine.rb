# frozen_string_literal: true

require 'find'

require_relative '../diagnostics/diagnostic'
require_relative '../graph/resource_graph'
require_relative '../build/secret_scanner'
require_relative '../model/capability_expander'

module Veltrunode
  module Validation
    class Engine
      IGNORED_SCAN_DIRECTORIES = %w[.git node_modules build .veltrunode tmp coverage .bundle .cache vendor].freeze

      NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

      def self.run(application, source_dir: nil)
        new(application, source_dir: source_dir).run
      end

      def self.run!(application, source_dir: nil)
        new(application, source_dir: source_dir).run!
      end

      def initialize(application, source_dir: nil)
        @application = application
        @source_dir = source_dir ? File.expand_path(source_dir.to_s) : nil
      end

      def run
        diagnostics = []

        diagnostics.concat(validate_resource_names)
        diagnostics.concat(validate_graph_and_references)
        diagnostics.concat(validate_runtime_compatibility)
        diagnostics.concat(validate_model_invariants)
        diagnostics.concat(validate_iam_capabilities)
        diagnostics.concat(validate_stage_policies)
        diagnostics.concat(validate_packaging_preconditions) if @source_dir

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

      attr_reader :application, :source_dir

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

      def validate_stage_policies
        diagnostics = []
        stage = (application.stage || 'dev').to_s.downcase
        is_prod = %w[prod production].include?(stage)
        policies_list = application.respond_to?(:policies) ? application.policies : []
        active_policies = Array(policies_list).select do |p|
          p.respond_to?(:applies_to?) && p.applies_to?(application.stage)
        end

        validate_stage_account_constraint(diagnostics, is_prod)
        validate_policy_wildcard_actions(diagnostics, active_policies)
        validate_policy_dlq_requirement(diagnostics, active_policies)
        validate_policy_log_retention(diagnostics, active_policies)
        validate_policy_public_storage(diagnostics, active_policies)

        diagnostics
      end

      def validate_stage_account_constraint(diagnostics, is_prod)
        return unless is_prod
        return unless application.account_constraint.nil? || application.account_constraint.to_s.strip.empty?

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-ACCOUNT-002',
          severity: :warning,
          summary: "Application stage '#{application.stage}' " \
                   'does not have an explicit account_constraint configured.',
          suggested_action: "Configure account_constraint for stage '#{application.stage}' " \
                            'to prevent accidental deployment to the wrong AWS account.',
          evidence: { 'stage' => application.stage }
        )
      end

      def validate_policy_wildcard_actions(diagnostics, active_policies)
        return unless active_policies.any?(&:deny_wildcard_actions?)

        expander = Model::CapabilityExpander.new(
          stage: 'dev',
          region: application.region,
          account: application.account_constraint
        )

        Array(application.functions).each do |fn|
          Array(fn.iam_capabilities).each do |cap|
            statements = expander.expand(cap)
            statements.each do |stmt|
              actions = Array(stmt['Action'])
              wildcards = actions.select { |a| a.to_s == '*' || a.to_s.end_with?(':*') }
              next if wildcards.empty?

              diagnostics << Diagnostics::Diagnostic.new(
                code: 'VLT-IAM-001',
                severity: :error,
                summary: "Wildcard IAM action '#{wildcards.first}' is denied by stage policy " \
                         "for function '#{fn.logical_name}'.",
                suggested_action: 'Specify explicit IAM actions instead of wildcards.',
                evidence: {
                  'function' => fn.logical_name,
                  'actions' => wildcards,
                  'stage' => application.stage,
                  'policy_violation' => true
                }
              )
            end
          rescue ValidationError => e
            diagnostics.concat(e.diagnostics)
          end
        end
      end

      def validate_policy_dlq_requirement(diagnostics, active_policies)
        return unless active_policies.any?(&:require_dlq?)

        Array(application.schedules).each do |sched|
          dlq_val = sched.respond_to?(:dlq) ? sched.dlq : nil
          next unless dlq_val.nil? || dlq_val.to_s.strip.empty?

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-SCHED-002',
            severity: :error,
            summary: "Schedule '#{sched.name}' must have a dead-letter queue (DLQ) configured " \
                     "under stage policy for '#{application.stage}'.",
            suggested_action: "Configure a DLQ for schedule '#{sched.name}' to capture failed invocations.",
            evidence: {
              'schedule' => sched.name,
              'stage' => application.stage,
              'policy_violation' => true
            }
          )
        end
      end

      def validate_policy_log_retention(diagnostics, active_policies)
        return unless active_policies.any?(&:require_log_retention?)

        runtime_defs = if application.respond_to?(:runtime_defaults) && application.runtime_defaults
                         application.runtime_defaults
                       else
                         {}
                       end
        defaults_logs = runtime_defs[:logs] || runtime_defs['logs']
        retention = defaults_logs && (defaults_logs[:retention_days] || defaults_logs['retention_days'])
        return if retention.to_i.positive?

        diagnostics << Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-001',
          severity: :error,
          summary: "Log retention period must be configured under stage policy for stage '#{application.stage}'.",
          suggested_action: 'Specify retention_days in application defaults (e.g. logs retention_days: 30).',
          evidence: {
            'stage' => application.stage,
            'policy_violation' => true
          }
        )
      end

      def validate_policy_public_storage(diagnostics, active_policies)
        return unless active_policies.any?(&:deny_public_storage?)

        Array(application.functions).each do |fn|
          Array(fn.iam_capabilities).each do |cap|
            params = if cap.respond_to?(:params)
                       cap.params
                     elsif cap.is_a?(Hash)
                       cap[:params] || cap['params'] || {}
                     else
                       {}
                     end
            next unless params.is_a?(Hash)

            is_public = params[:public] || params['public'] ||
                        %w[public-read public-read-write].include?(params[:acl] || params['acl'])
            next unless is_public

            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-IAM-001',
              severity: :error,
              summary: "Public storage access is denied by stage policy for function '#{fn.logical_name}'.",
              suggested_action: "Disable public access for storage capability in stage '#{application.stage}'.",
              evidence: {
                'function' => fn.logical_name,
                'stage' => application.stage,
                'policy_violation' => true
              }
            )
          end
        end
      end

      def validate_packaging_preconditions
        diagnostics = []
        return diagnostics unless source_dir && File.directory?(source_dir)

        real_source_dir = File.realpath(source_dir)
        base_prefix = real_source_dir.end_with?(File::SEPARATOR) ? real_source_dir : "#{real_source_dir}#{File::SEPARATOR}"

        # 1. Handler file existence
        Array(application.functions).each do |fn|
          handler_str = fn.respond_to?(:handler) ? fn.handler.to_s.strip : ''
          next if handler_str.empty?

          mod_path = handler_str.include?('.') ? handler_str.rpartition('.').first : handler_str
          next if mod_path.nil? || mod_path.empty?

          candidate_extensions = ['', '.rb', '.py', '.js', '.mjs', '.cjs']
          found = candidate_extensions.any? do |ext|
            rel = "#{mod_path}#{ext}"
            abs = File.expand_path(rel, real_source_dir)
            abs = File.realpath(abs) if File.exist?(abs)
            next false unless abs.start_with?(base_prefix)

            File.file?(abs)
          end

          next if found

          expected_files = candidate_extensions.map { |ext| "#{mod_path}#{ext}" }
          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-HANDLER-NOT-FOUND',
            severity: :error,
            summary: "Handler file not found for function '#{fn.logical_name}': " \
                     "expected one of #{expected_files.join(', ')}.",
            suggested_action: "Ensure the handler file exists in source directory '#{source_dir}' " \
                              "(handler: '#{handler_str}').",
            evidence: {
              'function' => fn.logical_name,
              'handler' => handler_str,
              'expected_files' => expected_files
            }
          )
        end

        # 2. Symlink checks with pruning and collecting files for secret scanning
        files_to_scan = []
        Find.find(source_dir) do |abs_path|
          if File.directory?(abs_path) && (abs_path != source_dir)
            basename = File.basename(abs_path)
            Find.prune if IGNORED_SCAN_DIRECTORIES.include?(basename)
          end

          rel_path = abs_path.start_with?(base_prefix) ? abs_path.delete_prefix(base_prefix) : File.basename(abs_path)

          if File.symlink?(abs_path)
            unless File.exist?(abs_path)
              diagnostics << Diagnostics::Diagnostic.new(
                code: 'VLT-BUILD-SYMLINK-TRAVERSAL',
                severity: :error,
                summary: "Broken symlink found in source directory: '#{rel_path}'",
                suggested_action: "Remove broken symlink '#{rel_path}' from source directory '#{source_dir}'.",
                evidence: { 'symlink' => rel_path }
              )
              next
            end

            real_target = File.realpath(abs_path)
            if real_target.start_with?(base_prefix)
              files_to_scan << rel_path
            else
              diagnostics << Diagnostics::Diagnostic.new(
                code: 'VLT-BUILD-SYMLINK-TRAVERSAL',
                severity: :error,
                summary: "Symlink points outside source directory: '#{rel_path}' -> '#{real_target}'",
                suggested_action: "Remove symlink pointing outside source directory '#{source_dir}' " \
                                  "(symlink: '#{rel_path}').",
                evidence: { 'symlink' => rel_path, 'target' => real_target }
              )
            end
          elsif File.file?(abs_path)
            files_to_scan << rel_path
          end
        end

        # 3. Secret scanning on source files
        diagnostics.concat(Build::SecretScanner.scan(source_dir: source_dir, entries: files_to_scan))

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
