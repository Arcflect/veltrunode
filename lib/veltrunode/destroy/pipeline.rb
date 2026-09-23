# frozen_string_literal: true

require_relative '../aws'
require_relative '../aws/account_region_guard'
require_relative '../aws/stack_destroyer'

module Veltrunode
  module Destroy
    class DestroyError < Veltrunode::Error
      attr_reader :exit_code, :diagnostics

      def initialize(message, exit_code: Pipeline::EXIT_DESTROY_FAILED, diagnostics: [])
        super(message)
        @exit_code = exit_code
        @diagnostics = Array(diagnostics)
      end
    end

    class DestroyResult
      attr_reader :status, :exit_code, :message, :stack_name, :resources, :events, :diagnostics, :stack_not_found

      def initialize(
        status:,
        exit_code: 0,
        message: nil,
        stack_name: nil,
        resources: [],
        events: [],
        diagnostics: [],
        stack_not_found: false
      )
        @status = status
        @exit_code = exit_code
        @message = message
        @stack_name = stack_name
        @resources = Array(resources).freeze
        @events = Array(events).freeze
        @diagnostics = Array(diagnostics).freeze
        @stack_not_found = stack_not_found
        freeze
      end

      def success?
        @status == :success
      end

      def stack_not_found?
        @stack_not_found
      end

      def to_h
        {
          'status' => @status.to_s,
          'exit_code' => @exit_code,
          'message' => @message,
          'stack_name' => @stack_name,
          'resources' => @resources.map { |r| r.respond_to?(:to_h) ? r.to_h : r },
          'events' => @events.map { |e| e.respond_to?(:to_h) ? e.to_h : e },
          'diagnostics' => @diagnostics.map { |d| d.respond_to?(:to_h) ? d.to_h : d },
          'stack_not_found' => @stack_not_found
        }.compact
      end
    end

    class Pipeline
      EXIT_SUCCESS = 0
      EXIT_INVALID_INPUT = 2
      EXIT_AWS_AUTH_FAILED = 4
      EXIT_DESTROY_FAILED = 7

      PROTECTED_STAGES = %w[prod production staging].freeze

      class << self
        def execute(application, source_dir: nil, options: {}, on_preview: nil, on_progress: nil, prompter: nil)
          new(
            application,
            source_dir: source_dir,
            options: options,
            on_preview: on_preview,
            on_progress: on_progress,
            prompter: prompter
          ).execute
        end
      end

      attr_reader :application, :source_dir, :options, :on_preview, :on_progress, :prompter

      def initialize(application, source_dir: nil, options: {}, on_preview: nil, on_progress: nil, prompter: nil)
        @application = application
        @source_dir = source_dir ? File.expand_path(source_dir.to_s) : Dir.pwd
        @options = options || {}
        @on_preview = on_preview
        @on_progress = on_progress
        @prompter = prompter
      end

      def execute
        # 1. AWS アカウント・リージョン検証
        guard_diags = step_aws_guard!

        destroyer = resolve_stack_destroyer
        stack_name = default_stack_name

        # 2. スタック存在確認
        unless destroyer.stack_exists?(stack_name)
          return DestroyResult.new(
            status: :success,
            exit_code: EXIT_SUCCESS,
            message: "Stack '#{stack_name}' does not exist or has already been deleted.",
            stack_name: stack_name,
            diagnostics: guard_diags,
            stack_not_found: true
          )
        end

        # 3. リソース一覧取得とプレビュー
        resources = step_describe_resources!(destroyer, stack_name)
        on_preview&.call(stack_name, resources)

        # 4. 承認確認
        step_approval!(stack_name)

        # 5. スタック削除 API 呼び出し
        step_delete_stack!(destroyer, stack_name)

        # 6. 削除完了待機
        events = step_wait_deletion!(destroyer, stack_name)

        DestroyResult.new(
          status: :success,
          exit_code: EXIT_SUCCESS,
          message: "Stack '#{stack_name}' has been successfully deleted.",
          stack_name: stack_name,
          resources: resources,
          events: events,
          diagnostics: guard_diags
        )
      rescue DestroyError => e
        DestroyResult.new(
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

      def step_aws_guard!
        guard_diags = Veltrunode::AWS::AccountRegionGuard.check(application)
        errors = guard_diags.select { |d| d.severity == :error }
        unless errors.empty?
          raise DestroyError.new(
            "Destroy aborted: AWS verification failed with #{errors.size} error(s).",
            exit_code: EXIT_AWS_AUTH_FAILED,
            diagnostics: guard_diags
          )
        end

        guard_diags
      rescue DestroyError
        raise
      rescue StandardError => e
        raise DestroyError.new("AWS account/region verification failed: #{e.message}",
                               exit_code: EXIT_AWS_AUTH_FAILED)
      end

      def step_describe_resources!(destroyer, stack_name)
        destroyer.describe_stack_resources(stack_name)
      rescue StandardError => e
        raise DestroyError.new(
          "Failed to retrieve resources for stack '#{stack_name}': #{e.message}",
          exit_code: EXIT_DESTROY_FAILED
        )
      end

      def step_approval!(stack_name)
        approved = request_approval(stack_name)
        return if approved

        raise DestroyError.new(
          "Destroy of stack '#{stack_name}' cancelled by user.",
          exit_code: EXIT_DESTROY_FAILED
        )
      end

      def request_approval(stack_name)
        return prompter.call(application.stage, stack_name) if prompter

        if protected_stage?
          request_protected_approval(stack_name)
        else
          request_standard_approval(stack_name)
        end
      end

      # 保護ステージ: スタック名の手入力を要求
      def request_protected_approval(stack_name)
        return false unless $stdin.respond_to?(:tty?) && $stdin.tty?

        $stdout.puts "This is a protected stage ('#{application.stage}'). This action is irreversible."
        $stdout.print "Type the stack name '#{stack_name}' to confirm deletion: "
        $stdout.flush
        input = $stdin.gets&.strip
        input == stack_name
      rescue StandardError
        false
      end

      # 非保護ステージ: y/n 確認プロンプト（--yes でスキップ可能）
      def request_standard_approval(stack_name)
        return true if options[:yes]
        return false unless $stdin.respond_to?(:tty?) && $stdin.tty?

        $stdout.print "Are you sure you want to delete stack '#{stack_name}'? [y/N]: "
        $stdout.flush
        answer = $stdin.gets&.strip&.downcase
        %w[y yes].include?(answer)
      rescue StandardError
        false
      end

      def step_delete_stack!(destroyer, stack_name)
        destroyer.delete_stack(stack_name)
      rescue StandardError => e
        raise DestroyError.new(
          "Failed to delete stack '#{stack_name}': #{e.message}",
          exit_code: EXIT_DESTROY_FAILED
        )
      end

      def step_wait_deletion!(destroyer, stack_name)
        destroyer.wait_for_stack_deletion(stack_name) do |event|
          on_progress&.call(event)
        end
      rescue StandardError => e
        raise DestroyError.new(
          "Stack deletion failed: #{e.message}",
          exit_code: EXIT_DESTROY_FAILED
        )
      end

      def default_stack_name
        "#{application.name}-#{application.stage}"
      end

      def resolve_stack_destroyer
        options[:stack_destroyer] || Veltrunode::AWS::StackDestroyer.new(application: application)
      end
    end
  end
end
