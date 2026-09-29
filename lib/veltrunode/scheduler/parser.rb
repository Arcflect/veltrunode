# frozen_string_literal: true

require_relative 'errors'
require_relative 'rate_expression'
require_relative 'at_expression'
require_relative 'cron_expression'

module Veltrunode
  module Scheduler
    # cron, rate, at 式の統合パーサー
    class Parser
      class << self
        # 与えられたスケジュール式を解析し、適切な Expression インスタンスを返します
        #
        # @param expression [String]
        # @return [RateExpression, AtExpression, CronExpression]
        def parse(expression)
          str = expression.to_s.strip

          case str
          when /\A\s*rate\s*\(/i
            RateExpression.new(str)
          when /\A\s*cron\s*\(/i
            CronExpression.new(str)
          when /\A\s*at\s*\(/i
            AtExpression.new(str)
          else
            raise ScheduleExpressionError.new(
              "Unknown schedule expression type in '#{str}'. " \
              'Expected cron(...), rate(...), or at(...).',
              expression: str,
              reason: 'unknown_schedule_type'
            )
          end
        end
      end
    end
  end
end
