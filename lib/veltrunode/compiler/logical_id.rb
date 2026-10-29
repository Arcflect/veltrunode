# frozen_string_literal: true

module Veltrunode
  module Compiler
    # CloudFormation 論理ID (Logical ID) 生成モジュール
    #
    # シンボリック名（:convert, :runtime_gems 等）から一貫性・決定論性を持つ
    # CloudFormation 論理ID（ConvertFunction, RuntimeGemsLayerVersion 等）を生成します。
    module LogicalId
      module_function

      # シンボリック名を PascalCase 文字列へ変換します
      #
      # @param name [String, Symbol, nil] 変換対象のシンボリック名
      # @return [String] PascalCase に変換された文字列
      def pascalize(name)
        return '' if name.nil?

        name.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
          part[0].upcase + part[1..]
        end.join
      end

      # Lambda 関数の論理IDを生成します（サフィックス: Function）
      #
      # @param name [String, Symbol] 関数シンボリック名 (例: :convert)
      # @return [String] 論理ID (例: "ConvertFunction")
      def for_function(name)
        base = pascalize(name)
        base = 'Function' if base.empty?
        base.end_with?('Function') ? base : "#{base}Function"
      end

      # Lambda Layer の論理IDを生成します（サフィックス: Layer）
      #
      # @param name [String, Symbol] Layer シンボリック名 (例: :runtime_gems)
      # @return [String] 論理ID (例: "RuntimeGemsLayer")
      def for_layer(name)
        base = pascalize(name)
        base = 'Layer' if base.empty?
        base.end_with?('Layer') ? base : "#{base}Layer"
      end

      # Lambda LayerVersion の論理IDを生成します（サフィックス: LayerVersion）
      #
      # @param name [String, Symbol] Layer シンボリック名 (例: :runtime_gems)
      # @return [String] 論理ID (例: "RuntimeGemsLayerVersion")
      def for_layer_version(name)
        base = pascalize(name)
        base = 'LayerVersion' if base.empty?
        base.end_with?('LayerVersion') ? base : "#{base}LayerVersion"
      end

      # EventBridge Schedule の論理IDを生成します（サフィックス: Schedule）
      #
      # @param name [String, Symbol] スケジュールシンボリック名 (例: :nightly)
      # @return [String] 論理ID (例: "NightlySchedule")
      def for_schedule(name)
        base = pascalize(name)
        base = 'Schedule' if base.empty?
        base.end_with?('Schedule') ? base : "#{base}Schedule"
      end

      # SQS キューの論理IDを生成します（サフィックス: Queue）
      #
      # @param name [String, Symbol] キューシンボリック名 (例: :nightly_dlq)
      # @return [String] 論理ID (例: "NightlyDlqQueue")
      def for_queue(name)
        base = pascalize(name)
        base = 'Queue' if base.empty?
        base.end_with?('Queue') ? base : "#{base}Queue"
      end

      # CloudWatch LogGroup の論理IDを生成します（サフィックス: LogGroup）
      #
      # @param name [String, Symbol] 関数シンボリック名または論理名 (例: :convert)
      # @return [String] 論理ID (例: "ConvertFunctionLogGroup")
      def for_log_group(name)
        str = name.to_s
        return str if str.end_with?('LogGroup')

        "#{for_function(str)}LogGroup"
      end

      # Lambda 実行ロールの論理IDを生成します（サフィックス: FunctionRole または Role）
      #
      # @param name [String, Symbol] 関数シンボリック名 (例: :convert)
      # @return [String] 論理ID (例: "ConvertFunctionRole")
      def for_lambda_role(name)
        fn_id = for_function(name)
        fn_id.end_with?('Role') ? fn_id : "#{fn_id}Role"
      end

      # Scheduler 実行ロールの論理IDを生成します（サフィックス: ScheduleRole または Role）
      #
      # @param name [String, Symbol] スケジュールシンボリック名 (例: :nightly)
      # @return [String] 論理ID (例: "NightlyScheduleRole")
      def for_scheduler_role(name)
        sched_id = for_schedule(name)
        sched_id.end_with?('Role') ? sched_id : "#{sched_id}Role"
      end

      # IAM ロールの論理IDを生成します
      #
      # @param name [String, Symbol] ターゲットシンボリック名
      # @param type [:lambda, :scheduler] ロール種別
      # @return [String] 論理ID
      def for_role(name, type: :lambda)
        type.to_sym == :scheduler ? for_scheduler_role(name) : for_lambda_role(name)
      end

      # リソース種別に応じた論理IDを汎用的に生成します
      #
      # @param name [String, Symbol] シンボリック名
      # @param type [Symbol, String] リソース種別 (:function, :layer, :layer_version, :schedule, :queue, :log_group, :role 等)
      # @return [String] 論理ID
      def for(name, type: :function)
        case type.to_sym
        when :function
          for_function(name)
        when :layer
          for_layer(name)
        when :layer_version
          for_layer_version(name)
        when :schedule
          for_schedule(name)
        when :queue
          for_queue(name)
        when :queue_alarm
          for_queue_alarm(name)
        when :log_group
          for_log_group(name)
        when :role, :lambda_role
          for_lambda_role(name)
        when :scheduler_role
          for_scheduler_role(name)
        when :access_point
          for_access_point(name)
        when :lambda_security_group
          for_lambda_security_group(name)
        when :efs_security_group
          for_efs_security_group(name)
        when :security_group_ingress
          for_security_group_ingress(name)
        when :security_group_egress
          for_security_group_egress(name)
        when :alarm, :cloudwatch_alarm
          suffix = 'Alarm'
          base = pascalize(name)
          base.end_with?(suffix) ? base : "#{base}#{suffix}"
        when :subscription_filter
          suffix = 'SubscriptionFilter'
          base = pascalize(name)
          base.end_with?(suffix) ? base : "#{base}#{suffix}"
        when :dashboard
          for_dashboard(name)
        when :event_invoke_config
          for_event_invoke_config(name)
        when :event_source_mapping
          for_event_source_mapping(name)
        else
          suffix = pascalize(type)
          base = pascalize(name)
          base = suffix if base.empty?
          base.end_with?(suffix) ? base : "#{base}#{suffix}"
        end
      end

      # EFS AccessPoint の論理IDを生成します（サフィックス: AccessPoint）
      #
      # @param name [String, Symbol] アクセスポイント名またはシンボリック名 (例: :shared_data)
      # @return [String] 論理ID (例: "SharedDataAccessPoint")
      def for_access_point(name)
        base = pascalize(name)
        base = 'AccessPoint' if base.empty?
        base.end_with?('AccessPoint') ? base : "#{base}AccessPoint"
      end

      # Lambda 側 SecurityGroup の論理IDを生成します
      #
      # @param name [String, Symbol] シンボリック名 (例: :storage, :default)
      # @return [String] 論理ID (例: "StorageLambdaSecurityGroup", "LambdaSecurityGroup")
      def for_lambda_security_group(name)
        base = pascalize(name)
        return 'LambdaSecurityGroup' if base.empty? || base == 'Default'
        return base if base.end_with?('LambdaSecurityGroup')

        "#{base}LambdaSecurityGroup"
      end

      # EFS 側 SecurityGroup の論理IDを生成します
      #
      # @param name [String, Symbol] シンボリック名 (例: :storage, :default)
      # @return [String] 論理ID (例: "StorageEfsSecurityGroup", "EfsSecurityGroup")
      def for_efs_security_group(name)
        base = pascalize(name)
        return 'EfsSecurityGroup' if base.empty? || base == 'Default' || base == 'Efs'
        return base if base.end_with?('EfsSecurityGroup')

        if base.end_with?('SecurityGroup')
          "#{base.sub(/SecurityGroup\z/, '')}EfsSecurityGroup"
        else
          "#{base}EfsSecurityGroup"
        end
      end

      # EFS SecurityGroup Ingress ルールの論理IDを生成します
      #
      # @param name [String, Symbol] シンボリック名 (例: :storage, :default)
      # @return [String] 論理ID (例: "StorageEfsSecurityGroupIngress", "EfsSecurityGroupIngress")
      def for_security_group_ingress(name)
        base = pascalize(name)
        return 'EfsSecurityGroupIngress' if base.empty? || base == 'Default' || base == 'Efs'

        "#{base}EfsSecurityGroupIngress"
      end

      # Lambda SecurityGroup Egress ルールの論理IDを生成します
      #
      # @param name [String, Symbol] シンボリック名 (例: :storage, :default)
      # @return [String] 論理ID (例: "StorageLambdaSecurityGroupEgress", "LambdaSecurityGroupEgress")
      def for_security_group_egress(name)
        base = pascalize(name)
        return 'LambdaSecurityGroupEgress' if base.empty? || base == 'Default' || base == 'Efs'

        "#{base}LambdaSecurityGroupEgress"
      end

      # Lambda 関数の CloudWatch メトリクスアラームの論理IDを生成します
      #
      # @param function_name [String, Symbol] 関数シンボリック名 (例: :convert)
      # @param metric [String, Symbol] メトリクス種別 (例: :errors, :duration, :throttles)
      # @return [String] 論理ID (例: "ConvertFunctionErrorsAlarm")
      def for_function_alarm(function_name, metric)
        fn_id = for_function(function_name)
        metric_str = pascalize(metric)
        "#{fn_id}#{metric_str}Alarm"
      end

      # SQS キューの CloudWatch メトリクスアラームの論理IDを生成します（サフィックス: QueueAlarm または Alarm）
      #
      # @param queue_name [String, Symbol] キューシンボリック名または論理名 (例: :nightly_dlq)
      # @return [String] 論理ID (例: "NightlyDlqQueueAlarm")
      def for_queue_alarm(queue_name)
        base = pascalize(queue_name)
        return 'QueueAlarm' if base.empty?
        return base if base.end_with?('QueueAlarm')
        return "#{base}Alarm" if base.end_with?('Queue')

        "#{base}QueueAlarm"
      end

      # CloudWatch Logs サブスクリプションフィルターの論理IDを生成します
      #
      # @param function_name [String, Symbol] 関数シンボリック名 (例: :worker)
      # @param filter_name [String, Symbol, nil] フィルター名 (例: :errors, :default)
      # @return [String] 論理ID (例: "WorkerFunctionSubscriptionFilter", "WorkerFunctionErrorsSubscriptionFilter")
      def for_subscription_filter(function_name, filter_name = nil)
        fn_id = for_function(function_name)
        suffix = if filter_name.nil? || filter_name.to_sym == :default
                   'SubscriptionFilter'
                 else
                   "#{pascalize(filter_name)}SubscriptionFilter"
                 end
        "#{fn_id}#{suffix}"
      end

      # CloudWatch Logs -> Lambda 呼び出し権限 (AWS::Lambda::Permission) の論理IDを生成します
      def for_logs_permission(function_name, filter_name = nil)
        fn_id = for_function(function_name)
        suffix = if filter_name.nil? || filter_name.to_sym == :default
                   'LogsPermission'
                 else
                   "#{pascalize(filter_name)}LogsPermission"
                 end
        "#{fn_id}#{suffix}"
      end

      # CloudWatch Logs -> Kinesis/Firehose 配信ロール (AWS::IAM::Role) の論理IDを生成します
      def for_logs_role(function_name, filter_name = nil)
        fn_id = for_function(function_name)
        suffix = if filter_name.nil? || filter_name.to_sym == :default
                   'LogsRole'
                 else
                   "#{pascalize(filter_name)}LogsRole"
                 end
        "#{fn_id}#{suffix}"
      end

      # CloudWatch Dashboard の論理IDを生成します（サフィックス: Dashboard）
      #
      # @param name [String, Symbol, nil] ダッシュボード名 (例: :default, :metrics)
      # @return [String] 論理ID (例: "Dashboard", "MetricsDashboard")
      def for_dashboard(name = nil)
        base = pascalize(name)
        return 'Dashboard' if base.empty? || base == 'Default'
        return base if base.end_with?('Dashboard')

        "#{base}Dashboard"
      end

      # Lambda 関数の EventInvokeConfig の論理IDを生成します（サフィックス: EventInvokeConfig）
      #
      # @param function_name [String, Symbol] 関数シンボリック名 (例: :convert)
      # @return [String] 論理ID (例: "ConvertFunctionEventInvokeConfig")
      def for_event_invoke_config(function_name)
        base = pascalize(function_name)
        return base if base.end_with?('EventInvokeConfig')

        fn_id = for_function(function_name)
        "#{fn_id}EventInvokeConfig"
      end

      # Lambda 関数の EventSourceMapping の論理IDを生成します（サフィックス: EventSourceMapping）
      #
      # @param function_name [String, Symbol] 関数シンボリック名 (例: :worker)
      # @param source_identifier [String, Symbol, nil] キュー名または識別子 (例: :orders_queue)
      # @return [String] 論理ID (例: "WorkerFunctionOrdersQueueEventSourceMapping")
      def for_event_source_mapping(function_name, source_identifier = nil)
        fn_id = for_function(function_name)
        if source_identifier && !source_identifier.to_s.strip.empty?
          src_part = pascalize(source_identifier)
          "#{fn_id}#{src_part}EventSourceMapping"
        else
          "#{fn_id}EventSourceMapping"
        end
      end
    end
  end
end
