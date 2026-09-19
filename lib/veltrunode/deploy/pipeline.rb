# frozen_string_literal: true

require_relative '../validation'
require_relative '../build'
require_relative '../aws'
require_relative '../aws/account_region_guard'
require_relative '../aws/change_set_manager'
require_relative '../aws/s3_uploader'

module Veltrunode
  module Deploy
    class DeployError < Veltrunode::Error
      attr_reader :exit_code, :diagnostics

      def initialize(message, exit_code: Pipeline::EXIT_DEPLOY_FAILED, diagnostics: [])
        super(message)
        @exit_code = exit_code
        @diagnostics = Array(diagnostics)
      end
    end

    class DeployResult
      attr_reader :status, :exit_code, :message, :stack_name, :change_set_name,
                  :summary, :changes, :events, :diagnostics, :no_changes

      def initialize(
        status:,
        exit_code: 0,
        message: nil,
        stack_name: nil,
        change_set_name: nil,
        summary: {},
        changes: [],
        events: [],
        diagnostics: [],
        no_changes: false
      )
        @status = status
        @exit_code = exit_code
        @message = message
        @stack_name = stack_name
        @change_set_name = change_set_name
        @summary = summary
        @changes = Array(changes).freeze
        @events = Array(events).freeze
        @diagnostics = Array(diagnostics).freeze
        @no_changes = no_changes
        freeze
      end

      def success?
        @status == :success
      end

      def no_changes?
        @no_changes
      end

      def to_h
        {
          'status' => @status.to_s,
          'exit_code' => @exit_code,
          'message' => @message,
          'stack_name' => @stack_name,
          'change_set_name' => @change_set_name,
          'summary' => @summary.transform_keys(&:to_s),
          'changes' => @changes.map { |c| c.respond_to?(:to_h) ? c.to_h : c },
          'events' => @events.map { |e| e.respond_to?(:to_h) ? e.to_h : e },
          'diagnostics' => @diagnostics.map { |d| d.respond_to?(:to_h) ? d.to_h : d },
          'no_changes' => @no_changes
        }.compact
      end
    end

    class Pipeline
      EXIT_SUCCESS = 0
      EXIT_INVALID_INPUT = 2
      EXIT_VALIDATION_FAILED = 3
      EXIT_AWS_AUTH_FAILED = 4
      EXIT_BUILD_FAILED = 5
      EXIT_PLAN_FAILED = 6
      EXIT_DEPLOY_FAILED = 7
      EXIT_POLICY_VIOLATION = 8

      PROTECTED_STAGES = %w[prod production staging].freeze

      class << self
        def execute(application, source_dir: nil, options: {}, on_progress: nil, on_plan: nil, prompter: nil)
          new(
            application,
            source_dir: source_dir,
            options: options,
            on_progress: on_progress,
            on_plan: on_plan,
            prompter: prompter
          ).execute
        end
      end

      attr_reader :application, :source_dir, :options, :on_progress, :on_plan, :prompter

      def initialize(application, source_dir: nil, options: {}, on_progress: nil, on_plan: nil, prompter: nil)
        @application = application
        @source_dir = source_dir ? File.expand_path(source_dir.to_s) : Dir.pwd
        @options = options || {}
        @on_progress = on_progress
        @on_plan = on_plan
        @prompter = prompter
      end

      def execute
        # 1. バリデーション
        step_validate!

        # 2. ビルド
        build_result = step_build!

        # 3. AWS アカウント・リージョンガード
        guard_diags = step_aws_guard!

        # 4. S3 アップロード
        step_s3_upload!(build_result)

        # 5. Change Set 作成・差分表示
        manager = resolve_change_set_manager
        cs_result = step_plan!(manager, build_result)

        if cs_result.changes.empty?
          return DeployResult.new(
            status: :success,
            exit_code: EXIT_SUCCESS,
            message: "No changes detected for stack '#{cs_result.stack_name}'. Stack is up to date.",
            stack_name: cs_result.stack_name,
            change_set_name: cs_result.change_set_name,
            summary: cs_result.summary,
            changes: [],
            diagnostics: guard_diags,
            no_changes: true
          )
        end

        # 6. 保護ステージの場合の承認確認
        step_approval!(cs_result)

        # 7. Change Set の実行
        step_execute_change_set!(manager, cs_result)

        # 8. スタック更新完了待機
        events = step_wait_stack!(manager, cs_result)

        DeployResult.new(
          status: :success,
          exit_code: EXIT_SUCCESS,
          message: "Deployment successful for stack '#{cs_result.stack_name}'.",
          stack_name: cs_result.stack_name,
          change_set_name: cs_result.change_set_name,
          summary: cs_result.summary,
          changes: cs_result.changes,
          events: events,
          diagnostics: guard_diags
        )
      rescue DeployError => e
        DeployResult.new(
          status: :error,
          exit_code: e.exit_code,
          message: e.message,
          diagnostics: e.diagnostics
        )
      end

      def protected_stage?
        stage = application.stage.to_s.downcase
        return true if PROTECTED_STAGES.include?(stage)

        has_policy = application.respond_to?(:policies) && Array(application.policies).any? do |p|
          p.applies_to?(application.stage)
        end
        return true if has_policy

        false
      end

      private

      def step_validate!
        diagnostics = Veltrunode::Validation::Engine.run(application, source_dir: source_dir)
        errors = diagnostics.select { |d| d.severity == :error }
        return if errors.empty?

        is_policy_violation = errors.any? do |d|
          d.code == 'VLT-IAM-001' || (d.evidence.is_a?(Hash) && d.evidence['policy_violation'])
        end
        exit_code = is_policy_violation ? EXIT_POLICY_VIOLATION : EXIT_VALIDATION_FAILED
        raise DeployError.new("Validation failed with #{errors.size} error(s).",
                              exit_code: exit_code,
                              diagnostics: diagnostics)
      end

      def step_build!
        no_cache = options[:no_cache] || false
        Veltrunode::Build::Pipeline.execute(application, source_dir: source_dir, no_cache: no_cache)
      rescue Veltrunode::ValidationError => e
        is_policy_violation = Array(e.diagnostics).any? do |d|
          d.code == 'VLT-IAM-001' || (d.evidence.is_a?(Hash) && d.evidence['policy_violation'])
        end
        exit_code = is_policy_violation ? EXIT_POLICY_VIOLATION : EXIT_VALIDATION_FAILED
        raise DeployError.new("Build validation failed: #{e.message}", exit_code: exit_code, diagnostics: e.diagnostics)
      rescue StandardError => e
        raise DeployError.new("Build failed: #{e.message}", exit_code: EXIT_BUILD_FAILED)
      end

      def step_aws_guard!
        guard_diags = Veltrunode::AWS::AccountRegionGuard.check(application)
        errors = guard_diags.select { |d| d.severity == :error }
        unless errors.empty?
          raise DeployError.new(
            "Deployment aborted: AWS verification failed with #{errors.size} error(s).",
            exit_code: EXIT_AWS_AUTH_FAILED,
            diagnostics: guard_diags
          )
        end

        guard_diags
      rescue DeployError
        raise
      rescue StandardError => e
        raise DeployError.new("AWS account/region verification failed: #{e.message}", exit_code: EXIT_AWS_AUTH_FAILED)
      end

      def step_s3_upload!(build_result)
        bucket = options[:bucket] || (application.respond_to?(:artifact_bucket) ? application.artifact_bucket : nil)
        return unless bucket && !bucket.to_s.strip.empty?

        uploader = options[:s3_uploader] || Veltrunode::AWS::S3Uploader.new(bucket: bucket, application: application)
        uploader.upload_and_update_template(build_result)
      rescue StandardError => e
        raise DeployError.new("S3 upload failed: #{e.message}", exit_code: EXIT_DEPLOY_FAILED)
      end

      def step_plan!(manager, build_result)
        cs_result = manager.create_and_describe_change_set(build_result.template_path)
        on_plan&.call(cs_result)
        cs_result
      rescue StandardError => e
        raise DeployError.new("Plan failed: #{e.message}", exit_code: EXIT_DEPLOY_FAILED)
      end

      def step_approval!(cs_result)
        return unless protected_stage?
        return if options[:yes]

        approved = request_approval(cs_result)
        return if approved

        raise DeployError.new("Deployment to protected stage '#{application.stage}' cancelled by user.",
                              exit_code: EXIT_DEPLOY_FAILED)
      end

      def request_approval(cs_result)
        return prompter.call(application.stage, cs_result) if prompter

        return false unless $stdin.respond_to?(:tty?) && $stdin.tty?

        $stdout.print "Deploying to protected stage '#{application.stage}'. Are you sure? [y/N]: "
        $stdout.flush
        answer = $stdin.gets&.strip&.downcase
        %w[y yes].include?(answer)
      rescue StandardError
        false
      end

      def step_execute_change_set!(manager, cs_result)
        manager.execute_change_set(
          stack_name: cs_result.stack_name,
          change_set_name: cs_result.change_set_name
        )
      rescue StandardError => e
        raise DeployError.new("Failed to execute Change Set: #{e.message}", exit_code: EXIT_DEPLOY_FAILED)
      end

      def step_wait_stack!(manager, cs_result)
        manager.wait_for_stack_completion(cs_result.stack_name) do |event|
          on_progress&.call(event)
        end
      rescue StandardError => e
        raise DeployError.new("Stack update failed: #{e.message}", exit_code: EXIT_DEPLOY_FAILED)
      end

      def resolve_change_set_manager
        options[:change_set_manager] || Veltrunode::AWS::ChangeSetManager.new(application: application)
      end
    end
  end
end
