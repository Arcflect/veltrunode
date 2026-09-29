# frozen_string_literal: true

require_relative '../validation'
require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Scheduler
    # 無効なスケジュール式が指定された場合に発生する例外クラス (VLT-SCHED-001)
    class ScheduleExpressionError < ValidationError
      attr_reader :expression, :reason

      def initialize(message, expression: nil, reason: nil, diagnostics: nil)
        @expression = expression
        @reason = reason

        diags = if diagnostics
                  diagnostics
                else
                  evidence = {
                    'expression' => expression&.to_s,
                    'reason' => reason&.to_s
                  }.compact

                  diag = Diagnostics::Diagnostic.new(
                    code: 'VLT-SCHED-001',
                    severity: :error,
                    summary: message.to_s,
                    suggested_action: 'Specify a valid cron, rate, or at expression ' \
                                      'according to AWS EventBridge Scheduler format.',
                    evidence: evidence
                  )
                  [diag]
                end

        super(message, diagnostics: diags)
      end
    end
  end
end
