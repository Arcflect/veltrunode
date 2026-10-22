# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/dashboard'

module Veltrunode
  module DSL
    # Application レベルの dashboard ブロック用 DSL ビルダー
    class DashboardBuilder < BaseBuilder
      def initialize(name = :default, title: nil, period: Model::Dashboard::DEFAULT_PERIOD, enabled: true)
        super()
        @name = name || :default
        @title = title
        @period = period || Model::Dashboard::DEFAULT_PERIOD
        @enabled = enabled
        @widget_entries = []
      end

      def title(val)
        @title = val
      end

      def period(seconds)
        @period = seconds
      end

      def enabled(val = true) # rubocop:disable Style/OptionalBooleanParameter
        @enabled = val ? true : false
      end

      def widget(metric, title: nil, stat: nil, period: nil, width: 12, height: 6, x: nil, y: nil)
        @widget_entries << {
          metric: metric,
          title: title,
          stat: stat,
          period: period,
          width: width,
          height: height,
          x: x,
          y: y
        }
      end

      def widgets(*metrics)
        metrics.flatten.each do |m|
          if m.is_a?(Hash)
            widget(m[:metric], **m.except(:metric))
          else
            widget(m)
          end
        end
      end

      def invocations(title: nil, stat: 'Sum', period: nil, width: 12, height: 6, x: nil, y: nil)
        widget(:invocations, title: title, stat: stat, period: period, width: width, height: height, x: x, y: y)
      end

      def errors(title: nil, stat: 'Sum', period: nil, width: 12, height: 6, x: nil, y: nil)
        widget(:errors, title: title, stat: stat, period: period, width: width, height: height, x: x, y: y)
      end

      def duration(title: nil, stat: 'Average', period: nil, width: 12, height: 6, x: nil, y: nil)
        widget(:duration, title: title, stat: stat, period: period, width: width, height: height, x: x, y: y)
      end

      def concurrent_executions(title: nil, stat: 'Maximum', period: nil, width: 12, height: 6, x: nil, y: nil)
        widget(:concurrent_executions, title: title, stat: stat, period: period, width: width, height: height, x: x,
                                       y: y)
      end

      def build
        Model::Dashboard.new(
          name: @name,
          title: @title,
          period: @period,
          widgets: @widget_entries,
          enabled: @enabled
        )
      end
    end
  end
end
