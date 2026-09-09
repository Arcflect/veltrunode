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
        when :log_group
          for_log_group(name)
        when :role, :lambda_role
          for_lambda_role(name)
        when :scheduler_role
          for_scheduler_role(name)
        else
          suffix = pascalize(type)
          base = pascalize(name)
          base = suffix if base.empty?
          base.end_with?(suffix) ? base : "#{base}#{suffix}"
        end
      end
    end
  end
end
