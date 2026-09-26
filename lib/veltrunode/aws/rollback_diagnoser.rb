# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module AWS
    # CloudFormation スタック更新失敗時のロールバック原因診断と対処方法提示を行うクラス
    class RollbackDiagnoser
      CATEGORY_IAM = 'iam_permission_denied'
      CATEGORY_LIMIT = 'resource_limit_exceeded'
      CATEGORY_EXISTS = 'resource_conflict'
      CATEGORY_CONFIG = 'invalid_configuration'
      CATEGORY_GENERAL = 'general_failure'

      CODE_IAM = 'VLT-CFN-ROLLBACK-IAM'
      CODE_LIMIT = 'VLT-CFN-ROLLBACK-LIMIT'
      CODE_EXISTS = 'VLT-CFN-ROLLBACK-EXISTS'
      CODE_CONFIG = 'VLT-CFN-ROLLBACK-CONFIG'
      CODE_GENERAL = 'VLT-CFN-ROLLBACK'

      IAM_KEYWORDS = [
        'is not authorized to perform',
        'AccessDenied',
        'Access Denied',
        'not authorized',
        'UnauthorizedOperation',
        'Missing permissions',
        'authorization error',
        'AccessDeniedException',
        'explicit deny'
      ].freeze
      IAM_PATTERN = Regexp.new(IAM_KEYWORDS.join('|'), Regexp::IGNORECASE)

      LIMIT_KEYWORDS = [
        'LimitExceeded',
        'ResourceLimitExceeded',
        'Limit exceeded',
        'Account limit exceeded',
        'QuotaExceeded',
        'TooManyRequestsException',
        'ServiceQuotaExceededException',
        'quota exceeded',
        'Rate exceeded',
        'maximum number of .* reached'
      ].freeze
      LIMIT_PATTERN = Regexp.new(LIMIT_KEYWORDS.join('|'), Regexp::IGNORECASE)

      EXISTS_KEYWORDS = [
        'already exists',
        'AlreadyExistsException',
        'ResourceConflictException',
        'ConflictException'
      ].freeze
      EXISTS_PATTERN = Regexp.new(EXISTS_KEYWORDS.join('|'), Regexp::IGNORECASE)

      CONFIG_KEYWORDS = [
        'InvalidParameterValue',
        'ValidationException',
        'InvalidParameter',
        'is not valid',
        'malformed',
        'InvalidRequestException'
      ].freeze
      CONFIG_PATTERN = Regexp.new(CONFIG_KEYWORDS.join('|'), Regexp::IGNORECASE)

      class << self
        # スタックイベントまたは CloudFormation クライアントからロールバック原因を診断します
        #
        # @param stack_name [String] 対象の CloudFormation スタック名
        # @param events [Array<StackEvent, Object>] 収集済みのスタックイベント配列
        # @param client [Aws::CloudFormation::Client, nil] CloudFormation クライアント（イベント再取得用）
        # @return [Array<Veltrunode::Diagnostics::Diagnostic>]
        def diagnose(stack_name:, events: [], client: nil)
          new(stack_name: stack_name, events: events, client: client).diagnose
        end
      end

      attr_reader :stack_name, :events, :client

      def initialize(stack_name:, events: [], client: nil)
        @stack_name = stack_name.to_s
        @events = Array(events)
        @client = client
      end

      # ロールバック原因を診断し、Diagnostic オブジェクトの配列を返します
      #
      # @return [Array<Veltrunode::Diagnostics::Diagnostic>]
      def diagnose
        all_events = resolve_events
        root_cause_events = find_root_cause_events(all_events)

        return [build_fallback_diagnostic] if root_cause_events.empty?

        root_cause_events.map do |event|
          build_diagnostic_for_event(event)
        end
      end

      private

      def resolve_events
        return @events unless @events.empty?
        return [] unless @client.respond_to?(:describe_stack_events)

        fetch_events_from_client
      rescue StandardError
        []
      end

      def fetch_events_from_client
        resp = @client.describe_stack_events(stack_name: @stack_name)
        raw_events = resp.respond_to?(:stack_events) ? Array(resp.stack_events) : []
        raw_events.map do |re|
          StackEvent.new(
            event_id: get_val(re, :event_id),
            logical_resource_id: get_val(re, :logical_resource_id),
            physical_resource_id: get_val(re, :physical_resource_id),
            resource_type: get_val(re, :resource_type),
            resource_status: get_val(re, :resource_status),
            resource_status_reason: get_val(re, :resource_status_reason),
            timestamp: get_val(re, :timestamp)
          )
        end
      rescue StandardError
        []
      end

      def find_root_cause_events(all_events)
        sorted_events = sort_events_chronologically(all_events)

        # 1. 直接失敗したリソースイベント（スタック自身およびキャンセルされたものを除く）
        resource_failures = sorted_events.select do |e|
          failed_status?(e) && !stack_resource?(e) && !cancelled_reason?(e)
        end

        return deduplicate_by_resource(resource_failures) unless resource_failures.empty?

        # 2. スタックイベントの理由文から原因リソースが特定できる場合
        stack_failure = sorted_events.reverse.find do |e|
          failed_status?(e) && stack_resource?(e) && !cancelled_reason?(e)
        end

        if stack_failure
          reason = get_val(stack_failure, :resource_status_reason).to_s
          target_resources = extract_failed_resource_names(reason)

          matched_events = sorted_events.select do |e|
            target_resources.include?(get_val(e, :logical_resource_id).to_s) && failed_status?(e)
          end

          return deduplicate_by_resource(matched_events) unless matched_events.empty?

          # スタック自身の失敗イベントを根本原因とする
          return [stack_failure]
        end

        # 3. その他何らかの失敗イベント
        any_failure = sorted_events.select { |e| failed_status?(e) }
        deduplicate_by_resource(any_failure)
      end

      def sort_events_chronologically(all_events)
        all_events.sort_by do |e|
          ts = get_val(e, :timestamp)
          if ts.respond_to?(:to_time)
            ts.to_time.to_f
          elsif ts.is_a?(Numeric)
            ts.to_f
          else
            0.0
          end
        end
      end

      def deduplicate_by_resource(events)
        seen = Set.new
        result = []
        events.each do |e|
          key = get_val(e, :logical_resource_id).to_s
          result << e if seen.add?(key)
        end
        result
      end

      def failed_status?(event)
        status = get_val(event, :resource_status).to_s.upcase
        status.end_with?('_FAILED')
      end

      def stack_resource?(event)
        type = get_val(event, :resource_type).to_s
        logical_id = get_val(event, :logical_resource_id).to_s
        type == 'AWS::CloudFormation::Stack' || logical_id == @stack_name
      end

      def cancelled_reason?(event)
        reason = get_val(event, :resource_status_reason).to_s.downcase
        reason.include?('cancelled') || reason.include?('canceled')
      end

      def extract_failed_resource_names(reason)
        # e.g., "The following resource(s) failed to create: [WorkerFunction, CacheTable]."
        # e.g., "The following resource(s) failed to update: [WorkerFunction]."
        match = reason.match(/failed to (?:create|update|delete):\s*\[([^\]]+)\]/i)
        return [] unless match

        match[1].split(',').map(&:strip)
      end

      def build_diagnostic_for_event(event)
        logical_id = get_val(event, :logical_resource_id).to_s
        physical_id = get_val(event, :physical_resource_id)&.to_s
        res_type = get_val(event, :resource_type).to_s
        status = get_val(event, :resource_status).to_s
        reason = get_val(event, :resource_status_reason).to_s

        code, category, suggested_action = analyze_failure(reason)

        summary = if reason.empty?
                    "Resource '#{logical_id}' (#{res_type}) failed with status '#{status}'"
                  else
                    "Resource '#{logical_id}' (#{res_type}) failed: #{reason}"
                  end

        evidence = {
          'logical_resource_id' => logical_id,
          'physical_resource_id' => physical_id,
          'resource_type' => res_type,
          'resource_status' => status,
          'status_reason' => reason,
          'stack_name' => @stack_name,
          'category' => category
        }.compact

        aws_resource_id = physical_id && !physical_id.empty? ? physical_id : logical_id

        Veltrunode::Diagnostics::Diagnostic.new(
          code: code,
          severity: :error,
          summary: summary,
          suggested_action: suggested_action,
          evidence: evidence,
          aws_resource_id: aws_resource_id
        )
      end

      def build_fallback_diagnostic
        Veltrunode::Diagnostics::Diagnostic.new(
          code: CODE_GENERAL,
          severity: :error,
          summary: "Stack '#{@stack_name}' update failed and rolled back.",
          suggested_action: 'Check the CloudFormation events in AWS Console or CLI for detailed failure reasons.',
          evidence: {
            'stack_name' => @stack_name,
            'category' => CATEGORY_GENERAL
          },
          aws_resource_id: @stack_name
        )
      end

      def analyze_failure(reason)
        r = reason.to_s

        if IAM_PATTERN.match?(r)
          action_name = extract_iam_action(r)
          action_suffix = action_name ? " for '#{action_name}'" : ''
          suggested = "Ensure the deployment IAM role or user has the necessary permissions#{action_suffix}. " \
                      'Check identity-based and resource-based policies and retry.'
          [CODE_IAM, CATEGORY_IAM, suggested]
        elsif LIMIT_PATTERN.match?(r)
          suggested = 'Request a service quota increase via AWS Service Quotas or delete unused resources in the ' \
                      'target account/region to free up capacity, then retry.'
          [CODE_LIMIT, CATEGORY_LIMIT, suggested]
        elsif EXISTS_PATTERN.match?(r)
          suggested = 'The resource already exists. Delete or rename the conflicting resource in AWS, ' \
                      'or update the logical resource configuration in Veltrunodefile, then retry.'
          [CODE_EXISTS, CATEGORY_EXISTS, suggested]
        elsif CONFIG_PATTERN.match?(r)
          suggested = 'Review the resource configuration and parameter values in Veltrunodefile, ' \
                      'correct any invalid properties or references, and retry.'
          [CODE_CONFIG, CATEGORY_CONFIG, suggested]
        else
          suggested = 'Inspect the CloudFormation event details and error message, ' \
                      'fix the underlying resource definition, and retry.'
          [CODE_GENERAL, CATEGORY_GENERAL, suggested]
        end
      end

      def extract_iam_action(reason)
        match = reason.match(/(?:perform|action):\s*([a-zA-Z0-9:-]+)/i) ||
                reason.match(/action\s*['"]?([a-zA-Z0-9:-]+)['"]?/i)
        match ? match[1] : nil
      end

      def get_val(obj, key)
        if obj.respond_to?(key)
          obj.public_send(key)
        elsif obj.is_a?(Hash)
          obj[key.to_s] || obj[key.to_sym]
        end
      end
    end
  end
end
