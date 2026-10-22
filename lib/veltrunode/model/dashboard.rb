# frozen_string_literal: true

require_relative '../validation'

module Veltrunode
  module Model
    class Dashboard
      DEFAULT_PERIOD = 300

      METRIC_DEFAULTS = {
        invocations: { title: 'Invocations', stat: 'Sum' },
        errors: { title: 'Errors', stat: 'Sum' },
        duration: { title: 'Duration', stat: 'Average' },
        concurrent_executions: { title: 'Concurrent Executions', stat: 'Maximum' }
      }.freeze

      DEFAULT_METRICS = METRIC_DEFAULTS.keys.freeze

      class Widget
        attr_reader :metric, :title, :stat, :period, :width, :height, :x, :y

        def initialize(metric:, title: nil, stat: nil, period: nil, width: 12, height: 6, x: 0, y: 0)
          metric_sym = metric.to_s.downcase.to_sym
          defaults = METRIC_DEFAULTS[metric_sym] || {}

          @metric = metric.to_s.freeze
          @title = (title || defaults[:title] || metric.to_s.capitalize).freeze
          @stat = (stat || defaults[:stat] || 'Average').to_s.freeze
          @period = period&.to_i
          @width = width.to_i
          @height = height.to_i
          @x = x.to_i
          @y = y.to_i

          validate!
          freeze
        end

        def to_h
          {
            'metric' => @metric,
            'title' => @title,
            'stat' => @stat,
            'period' => @period,
            'width' => @width,
            'height' => @height,
            'x' => @x,
            'y' => @y
          }.compact
        end

        private

        def validate!
          raise ValidationError, 'Widget metric is required' if @metric.empty?
          raise ValidationError, "Invalid widget width: #{@width} (must be 1..24)" unless (1..24).cover?(@width)
          raise ValidationError, "Invalid widget height: #{@height} (must be 1..24)" unless (1..24).cover?(@height)
          raise ValidationError, "Invalid widget x coordinate: #{@x}" if @x.negative?
          raise ValidationError, "Invalid widget y coordinate: #{@y}" if @y.negative?

          return unless @period && (@period < 10 || (@period % 10).nonzero?)

          raise ValidationError, "Invalid widget period: #{@period} (must be a positive multiple of 10)"
        end
      end

      attr_reader :name, :title, :period, :widgets

      def initialize(name: :default, title: nil, period: DEFAULT_PERIOD, widgets: [], enabled: true)
        @name = (name || :default).to_s.freeze
        @period = (period || DEFAULT_PERIOD).to_i
        @title = title&.to_s&.freeze
        @enabled = enabled ? true : false

        validate!

        raw_widgets = Array(widgets)
        @widgets = if raw_widgets.empty?
                     build_default_widgets
                   else
                     normalize_widgets(raw_widgets)
                   end.freeze

        freeze
      end

      def enabled?
        @enabled
      end

      def to_h
        {
          'name' => @name,
          'title' => @title,
          'period' => @period,
          'enabled' => @enabled,
          'widgets' => @widgets.map(&:to_h)
        }.compact
      end

      private

      def validate!
        raise ValidationError, 'Dashboard name is required' if @name.empty?
        return unless @period < 10 || (@period % 10).nonzero?

        raise ValidationError, "Invalid dashboard period: #{@period} (must be a positive multiple of 10)"
      end

      def build_default_widgets
        DEFAULT_METRICS.each_with_index.map do |metric_sym, idx|
          col = idx % 2
          row = idx / 2
          Widget.new(
            metric: metric_sym,
            period: @period,
            width: 12,
            height: 6,
            x: col * 12,
            y: row * 6
          )
        end
      end

      def normalize_widgets(items)
        items.each_with_index.map do |item, idx|
          if item.is_a?(Widget)
            item
          elsif item.is_a?(Hash)
            opts = item.transform_keys(&:to_sym)
            col = idx % 2
            row = idx / 2
            Widget.new(
              metric: opts[:metric],
              title: opts[:title],
              stat: opts[:stat],
              period: opts[:period] || @period,
              width: opts[:width] || 12,
              height: opts[:height] || 6,
              x: opts[:x] || (col * 12),
              y: opts[:y] || (row * 6)
            )
          else
            # Symbol or String
            metric_sym = item.to_s.to_sym
            col = idx % 2
            row = idx / 2
            Widget.new(
              metric: metric_sym,
              period: @period,
              width: 12,
              height: 6,
              x: col * 12,
              y: row * 6
            )
          end
        end
      end
    end
  end
end
