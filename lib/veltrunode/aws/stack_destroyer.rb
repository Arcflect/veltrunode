# frozen_string_literal: true

module Veltrunode
  module AWS
    # スタック削除操作に関するエラー
    class StackDestroyError < Veltrunode::Error
      attr_reader :stack_name, :original_error

      def initialize(message, stack_name: nil, original_error: nil)
        super(message)
        @stack_name = stack_name
        @original_error = original_error
      end
    end

    # CloudFormation スタック上のリソースを表す値オブジェクト
    class StackResource
      attr_reader :logical_resource_id, :physical_resource_id, :resource_type, :resource_status

      def initialize(
        logical_resource_id:,
        resource_type:,
        resource_status:,
        physical_resource_id: nil
      )
        @logical_resource_id = logical_resource_id.to_s.freeze
        @physical_resource_id = physical_resource_id&.to_s&.freeze
        @resource_type = resource_type.to_s.freeze
        @resource_status = resource_status.to_s.freeze
        freeze
      end

      def to_h
        {
          'logical_resource_id' => @logical_resource_id,
          'physical_resource_id' => @physical_resource_id,
          'resource_type' => @resource_type,
          'resource_status' => @resource_status
        }
      end
    end

    # CloudFormation スタックの削除操作を担うアダプター（副作用境界）
    #
    # AWS SDK を直接扱う Side Effect 境界レイヤー。
    # Internal Model への依存なし。
    class StackDestroyer
      DELETE_COMPLETE_STATUS = 'DELETE_COMPLETE'
      DELETE_FAILED_STATUS = 'DELETE_FAILED'
      DELETION_IN_PROGRESS_STATUS = 'DELETE_IN_PROGRESS'

      FAILED_STATUSES = %w[
        DELETE_FAILED
        ROLLBACK_FAILED
        UPDATE_ROLLBACK_FAILED
      ].freeze

      attr_reader :application, :poll_interval, :max_polls

      # @param application [Veltrunode::Model::Application]
      # @param cfn_client [Aws::CloudFormation::Client, nil] DI 用クライアント
      # @param poll_interval [Numeric] ステータスポーリングの間隔（秒）
      # @param max_polls [Integer] 最大ポーリング回数
      def initialize(application:, cfn_client: nil, poll_interval: 1, max_polls: 180)
        raise ArgumentError, 'Application model must be provided' unless application

        @application = application
        @cfn_client = cfn_client
        @poll_interval = poll_interval
        @max_polls = max_polls
      end

      # スタックが削除可能な状態で存在するかを確認します
      #
      # @param stack_name [String]
      # @return [Boolean] true: スタックが存在する、false: 存在しないか DELETE_COMPLETE
      def stack_exists?(stack_name)
        stacks = client.describe_stacks(stack_name: stack_name)
        stack = stacks.stacks.first
        return false unless stack

        stack.stack_status.to_s.upcase != DELETE_COMPLETE_STATUS
      rescue StandardError => e
        return false if stack_not_found_error?(e)

        raise StackDestroyError.new(
          "Failed to describe stack '#{stack_name}': #{e.message}",
          stack_name: stack_name,
          original_error: e
        )
      end

      # スタック内の全リソースを一覧取得します
      #
      # @param stack_name [String]
      # @return [Array<StackResource>]
      def describe_stack_resources(stack_name)
        resp = client.describe_stack_resources(stack_name: stack_name)
        raw = resp.respond_to?(:stack_resources) ? Array(resp.stack_resources) : []

        raw.map do |r|
          StackResource.new(
            logical_resource_id: get_val(r, :logical_resource_id),
            physical_resource_id: get_val(r, :physical_resource_id),
            resource_type: get_val(r, :resource_type),
            resource_status: get_val(r, :resource_status)
          )
        end
      rescue StandardError => e
        raise StackDestroyError.new(
          "Failed to describe resources for stack '#{stack_name}': #{e.message}",
          stack_name: stack_name,
          original_error: e
        )
      end

      # CloudFormation DeleteStack API を呼び出します
      #
      # @param stack_name [String]
      def delete_stack(stack_name)
        client.delete_stack(stack_name: stack_name)
      rescue StandardError => e
        raise StackDestroyError.new(
          "Failed to delete stack '#{stack_name}': #{e.message}",
          stack_name: stack_name,
          original_error: e
        )
      end

      # スタック削除の完了を待機し、スタックイベントを逐次通知します
      #
      # @param stack_name [String]
      # @yieldparam [StackEvent] event
      # @return [Array<StackEvent>]
      def wait_for_stack_deletion(stack_name, &on_progress)
        seen_event_ids = fetch_initial_event_ids(stack_name)
        collected_events = []

        @max_polls.times do
          new_events = fetch_new_stack_events(stack_name, seen_event_ids)
          new_events.each do |event|
            collected_events << event
            on_progress&.call(event)
          end

          # スタックが消えた（削除完了）かチェック
          return collected_events unless stack_exists_for_polling?(stack_name)

          status = current_stack_status(stack_name)

          if status == DELETE_COMPLETE_STATUS || status.nil?
            return collected_events
          elsif FAILED_STATUSES.include?(status)
            raise StackDestroyError.new(
              "Stack '#{stack_name}' deletion failed with status '#{status}'",
              stack_name: stack_name
            )
          end

          sleep(@poll_interval) if @poll_interval.to_f.positive?
        end

        raise StackDestroyError.new(
          "Timed out waiting for stack '#{stack_name}' deletion.",
          stack_name: stack_name
        )
      end

      private

      def default_stack_name
        "#{@application.name}-#{@application.stage}"
      end

      def client
        @client ||= resolve_cfn_client
      end

      def resolve_cfn_client
        return @cfn_client if @cfn_client

        begin
          require 'aws-sdk-cloudformation' unless defined?(::Aws::CloudFormation::Client)
          ::Aws::CloudFormation::Client.new(region: resolve_region)
        rescue LoadError => e
          raise StackDestroyError,
                "AWS SDK (aws-sdk-cloudformation) is not available: #{e.message}. " \
                'Please install aws-sdk-cloudformation.'
        rescue StandardError => e
          raise StackDestroyError.new("Failed to initialize CloudFormation client: #{e.message}", original_error: e)
        end
      end

      def resolve_region
        if @application.respond_to?(:region) && !@application.region.to_s.strip.empty?
          @application.region.to_s.strip
        else
          'ap-northeast-1'
        end
      end

      def stack_not_found_error?(error)
        msg = error.message.to_s
        error_class = error.class.name.to_s
        msg.include?('does not exist') || msg.include?('Stack with id') || error_class.include?('ValidationError')
      end

      # wait_for_stack_deletion でのポーリング用（例外を飲み込む）
      def stack_exists_for_polling?(stack_name)
        stacks = client.describe_stacks(stack_name: stack_name)
        stack = stacks.stacks.first
        return false unless stack

        stack.stack_status.to_s.upcase != DELETE_COMPLETE_STATUS
      rescue StandardError => e
        return false if stack_not_found_error?(e)

        false
      end

      def current_stack_status(stack_name)
        stacks = client.describe_stacks(stack_name: stack_name)
        stack = stacks.stacks.first
        stack&.stack_status&.to_s&.upcase
      rescue StandardError
        nil
      end

      def fetch_initial_event_ids(stack_name)
        resp = client.describe_stack_events(stack_name: stack_name)
        events = resp.respond_to?(:stack_events) ? Array(resp.stack_events) : []
        events.map { |e| get_val(e, :event_id) }.compact.to_set
      rescue StandardError
        Set.new
      end

      def fetch_new_stack_events(stack_name, seen_event_ids)
        resp = client.describe_stack_events(stack_name: stack_name)
        raw_events = resp.respond_to?(:stack_events) ? Array(resp.stack_events) : []
        new_events = []

        raw_events.reverse_each do |re|
          eid = get_val(re, :event_id)
          next unless eid
          next unless seen_event_ids.add?(eid)

          new_events << StackEvent.new(
            event_id: eid,
            logical_resource_id: get_val(re, :logical_resource_id),
            physical_resource_id: get_val(re, :physical_resource_id),
            resource_type: get_val(re, :resource_type),
            resource_status: get_val(re, :resource_status),
            resource_status_reason: get_val(re, :resource_status_reason),
            timestamp: get_val(re, :timestamp)
          )
        end

        new_events
      rescue StandardError
        []
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
