# frozen_string_literal: true

require_relative 'scheduler/errors'
require_relative 'scheduler/timezone_helper'
require_relative 'scheduler/base_expression'
require_relative 'scheduler/rate_expression'
require_relative 'scheduler/at_expression'
require_relative 'scheduler/cron_field'
require_relative 'scheduler/cron_expression'
require_relative 'scheduler/parser'
require_relative 'scheduler/preview_engine'

module Veltrunode
  module Scheduler
    class << self
      def parse(expression)
        Parser.parse(expression)
      end

      def preview(schedule, count: 10, from_time: Time.now)
        PreviewEngine.preview(schedule, count: count, from_time: from_time)
      end
    end
  end
end
