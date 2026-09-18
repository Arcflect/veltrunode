# frozen_string_literal: true

require 'securerandom'
require 'yaml'

module Veltrunode
  module AWS
    # Change Set 操作に関するエラー
    class ChangeSetError < Veltrunode::Error
      attr_reader :stack_name, :change_set_name, :original_error

      def initialize(message, stack_name: nil, change_set_name: nil, original_error: nil)
        super(message)
        @stack_name = stack_name
        @change_set_name = change_set_name
        @original_error = original_error
      end
    end

    # 個々のリソース変更を表す値オブジェクト
    class ResourceChange
      attr_reader :logical_resource_id, :physical_resource_id, :resource_type, :action, :replacement, :display_action, :details

      # @param logical_resource_id [String]
      # @param physical_resource_id [String, nil]
      # @param resource_type [String]
      # @param action [String] ("Add", "Modify", "Remove", "Replace")
      # @param replacement [String, nil] ("Always", "Never", "Conditional")
      # @param display_action [Symbol] (:add, :modify, :remove, :replace)
      # @param details [Array, Hash, nil]
      def initialize(
        logical_resource_id:,
        physical_resource_id: nil,
        resource_type:,
        action:,
        replacement: nil,
        display_action: nil,
        details: nil
      )
        @logical_resource_id = logical_resource_id.to_s.freeze
        @physical_resource_id = physical_resource_id&.to_s&.freeze
        @resource_type = resource_type.to_s.freeze
        @replacement = replacement&.to_s&.freeze
        @display_action = (display_action || self.class.determine_display_action(action, replacement)).to_sym
        @action = (@display_action == :replace ? 'Replace' : action.to_s.capitalize).freeze
        @details = details.freeze
        freeze
      end

      def replace?
        @display_action == :replace
      end

      def add?
        @display_action == :add
      end

      def modify?
        @display_action == :modify
      end

      def remove?
        @display_action == :remove
      end

      def to_h
        {
          'logical_resource_id' => @logical_resource_id,
          'physical_resource_id' => @physical_resource_id,
          'resource_type' => @resource_type,
          'action' => @action,
          'replacement' => @replacement,
          'display_action' => @display_action.to_s
        }
      end

      def self.determine_display_action(action, replacement)
        act = action.to_s.capitalize
        rep = replacement.to_s.capitalize

        if act == 'Add'
          :add
        elsif act == 'Remove'
          :remove
        elsif act == 'Replace' || (act == 'Modify' && %w[Always Conditional True].include?(rep))
          :replace
        else
          :modify
        end
      end
    end

    # Change Set 全体の結果を表す値オブジェクト
    class ChangeSetResult
      attr_reader :stack_name, :change_set_name, :changes, :summary

      def initialize(stack_name:, change_set_name:, changes: [])
        @stack_name = stack_name.to_s.freeze
        @change_set_name = change_set_name.to_s.freeze
        @changes = Array(changes).freeze

        @summary = {
          add: @changes.count(&:add?),
          modify: @changes.count(&:modify?),
          replace: @changes.count(&:replace?),
          remove: @changes.count(&:remove?)
        }.freeze

        freeze
      end

      def empty?
        @changes.empty?
      end

      def to_h
        {
          'stack_name' => @stack_name,
          'change_set_name' => @change_set_name,
          'summary' => @summary.transform_keys(&:to_s),
          'changes' => @changes.map(&:to_h)
        }
      end
    end

    # CloudFormation Change Set を作成し、ステータスを監視・解析するマネージャ
    class ChangeSetManager
      attr_reader :application, :poll_interval, :max_polls

      # @param application [Veltrunode::Model::Application]
      # @param cfn_client [Aws::CloudFormation::Client, nil] DI 用クライアント
      # @param poll_interval [Numeric] ステータスポーリングの間隔（秒）
      # @param max_polls [Integer] 最大ポーリング回数
      def initialize(application:, cfn_client: nil, poll_interval: 1, max_polls: 60)
        raise ArgumentError, 'Application model must be provided' unless application

        @application = application
        @cfn_client = cfn_client
        @poll_interval = poll_interval
        @max_polls = max_polls
      end

      # CloudFormation Change Set を作成し、完了まで待機した上で結果を取得します
      #
      # @param template_data_or_path [String, Hash] CloudFormation テンプレート
      # @param stack_name [String, nil] カスタムスタック名（未指定時は app.name-app.stage）
      # @param change_set_name [String, nil] カスタム変更セット名
      # @return [ChangeSetResult]
      def create_and_describe_change_set(template_data_or_path, stack_name: nil, change_set_name: nil)
        resolved_stack_name = stack_name.to_s.strip.empty? ? default_stack_name : stack_name.to_s.strip
        resolved_change_set_name = change_set_name.to_s.strip.empty? ? default_change_set_name : change_set_name.to_s.strip
        template_body = load_template_body(template_data_or_path)

        change_set_type = determine_change_set_type(resolved_stack_name)

        execute_create_change_set(
          stack_name: resolved_stack_name,
          change_set_name: resolved_change_set_name,
          template_body: template_body,
          change_set_type: change_set_type
        )

        describe_result = poll_change_set_status(resolved_stack_name, resolved_change_set_name)

        parse_change_set_response(describe_result, stack_name: resolved_stack_name, change_set_name: resolved_change_set_name)
      end

      private

      def default_stack_name
        "#{@application.name}-#{@application.stage}"
      end

      def default_change_set_name
        "veltrunode-plan-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
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
          raise ChangeSetError.new("AWS SDK (aws-sdk-cloudformation) is not available: #{e.message}. Please install aws-sdk-cloudformation.")
        rescue StandardError => e
          raise ChangeSetError.new("Failed to initialize CloudFormation client: #{e.message}", original_error: e)
        end
      end

      def resolve_region
        if @application.respond_to?(:region) && !@application.region.to_s.strip.empty?
          @application.region.to_s.strip
        else
          'ap-northeast-1'
        end
      end

      def determine_change_set_type(stack_name)
        stacks = client.describe_stacks(stack_name: stack_name)
        stack = stacks.stacks.first
        if stack && stack.stack_status != 'DELETE_COMPLETE'
          'UPDATE'
        else
          'CREATE'
        end
      rescue StandardError => e
        if stack_not_found_error?(e)
          'CREATE'
        else
          raise ChangeSetError.new(
            "Failed to describe stack '#{stack_name}': #{e.message}",
            stack_name: stack_name,
            original_error: e
          )
        end
      end

      def stack_not_found_error?(error)
        msg = error.message.to_s
        error_class = error.class.name.to_s
        msg.include?('does not exist') || msg.include?('Stack with id') || error_class.include?('ValidationError')
      end

      def execute_create_change_set(stack_name:, change_set_name:, template_body:, change_set_type:)
        client.create_change_set(
          stack_name: stack_name,
          change_set_name: change_set_name,
          template_body: template_body,
          capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND],
          change_set_type: change_set_type
        )
      rescue StandardError => e
        raise ChangeSetError.new(
          "Failed to create Change Set '#{change_set_name}' for stack '#{stack_name}': #{e.message}",
          stack_name: stack_name,
          change_set_name: change_set_name,
          original_error: e
        )
      end

      def poll_change_set_status(stack_name, change_set_name)
        @max_polls.times do
          resp = client.describe_change_set(stack_name: stack_name, change_set_name: change_set_name)
          status = resp.status.to_s.upcase

          return resp if %w[CREATE_COMPLETE FAILED].include?(status)

          sleep(@poll_interval) if @poll_interval.to_f > 0
        end

        raise ChangeSetError.new(
          "Timed out waiting for Change Set '#{change_set_name}' status for stack '#{stack_name}'.",
          stack_name: stack_name,
          change_set_name: change_set_name
        )
      rescue ChangeSetError
        raise
      rescue StandardError => e
        raise ChangeSetError.new(
          "Failed to describe Change Set '#{change_set_name}' for stack '#{stack_name}': #{e.message}",
          stack_name: stack_name,
          change_set_name: change_set_name,
          original_error: e
        )
      end

      def parse_change_set_response(response, stack_name:, change_set_name:)
        status = response.status.to_s.upcase
        reason = response.respond_to?(:status_reason) ? response.status_reason.to_s : (response.respond_to?(:reason) ? response.reason.to_s : '')

        if status == 'FAILED'
          if no_changes_reason?(reason)
            return ChangeSetResult.new(
              stack_name: stack_name,
              change_set_name: change_set_name,
              changes: []
            )
          else
            raise ChangeSetError.new(
              "CloudFormation Change Set creation failed: #{reason.empty? ? 'Unknown error' : reason}",
              stack_name: stack_name,
              change_set_name: change_set_name
            )
          end
        end

        raw_changes = response.respond_to?(:changes) ? Array(response.changes) : []
        resource_changes = []

        raw_changes.each do |change|
          type = change.respond_to?(:type) ? change.type : (change['type'] || change[:type])
          next unless type.to_s.capitalize == 'Resource'

          rc = change.respond_to?(:resource_change) ? change.resource_change : (change['resource_change'] || change[:resource_change])
          next unless rc

          logical_id = get_val(rc, :logical_resource_id)
          physical_id = get_val(rc, :physical_resource_id)
          res_type = get_val(rc, :resource_type)
          action = get_val(rc, :action)
          replacement = get_val(rc, :replacement)
          details = get_val(rc, :details)

          display_action = ResourceChange.determine_display_action(action, replacement)
          norm_action = display_action == :replace ? 'Replace' : action.to_s.capitalize

          resource_changes << ResourceChange.new(
            logical_resource_id: logical_id,
            physical_resource_id: physical_id,
            resource_type: res_type,
            action: norm_action,
            replacement: replacement,
            display_action: display_action,
            details: details
          )
        end

        ChangeSetResult.new(
          stack_name: stack_name,
          change_set_name: change_set_name,
          changes: resource_changes
        )
      end

      def no_changes_reason?(reason)
        r = reason.to_s.downcase
        r.include?('no changes') || r.include?("didn't contain changes") || r.include?('causes no changes')
      end

      def get_val(obj, key)
        if obj.respond_to?(key)
          obj.public_send(key)
        elsif obj.is_a?(Hash)
          obj[key.to_s] || obj[key.to_sym]
        end
      end

      def load_template_body(template_data_or_path)
        if template_data_or_path.is_a?(String)
          if File.file?(template_data_or_path)
            File.read(template_data_or_path)
          else
            template_data_or_path
          end
        elsif template_data_or_path.is_a?(Hash)
          YAML.dump(template_data_or_path)
        else
          raise ArgumentError, "Invalid template data or path: #{template_data_or_path.inspect}"
        end
      end
    end
  end
end
