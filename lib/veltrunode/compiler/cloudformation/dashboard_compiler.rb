# frozen_string_literal: true

require 'json'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # CloudWatch Dashboard (AWS::CloudWatch::Dashboard) の CloudFormation コンパイラ
      class DashboardCompiler
        attr_reader :dashboard, :functions, :context

        KNOWN_METRICS = {
          'invocations' => 'Invocations',
          'errors' => 'Errors',
          'duration' => 'Duration',
          'concurrent_executions' => 'ConcurrentExecutions',
          'concurrentexecutions' => 'ConcurrentExecutions',
          'throttles' => 'Throttles'
        }.freeze

        class << self
          def compile(dashboard, functions: [], context: {})
            new(dashboard, functions: functions, context: context).to_h
          end

          def logical_id_for(dashboard_name = nil)
            LogicalId.for_dashboard(dashboard_name)
          end
        end

        def initialize(dashboard, functions: [], context: {})
          @dashboard = dashboard
          @functions = Array(functions).dup.freeze
          @context = freeze_hash(context)
        end

        def to_h
          {
            logical_id => resource_definition
          }
        end

        def logical_id
          self.class.logical_id_for(dashboard.name)
        end

        def resource_type
          'AWS::CloudWatch::Dashboard'
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => deep_sort_keys(properties)
          }
        end

        def properties
          {
            'DashboardName' => dashboard_name,
            'DashboardBody' => {
              'Fn::Sub' => JSON.generate(deep_sort_keys(dashboard_body_hash))
            }
          }
        end

        private

        def dashboard_name
          if dashboard.name && dashboard.name.to_s != 'default'
            { 'Fn::Sub' => "${AWS::StackName}-#{logical_id}" }
          else
            { 'Fn::Sub' => '${AWS::StackName}-Dashboard' }
          end
        end

        def dashboard_body_hash
          widgets = dashboard.widgets.map do |widget|
            format_widget(widget)
          end

          {
            'widgets' => widgets
          }
        end

        def format_widget(widget)
          metric_name = normalize_metric(widget.metric)

          metrics = if functions.empty?
                      [['AWS/Lambda', metric_name]]
                    else
                      functions.map do |fn|
                        fn_name = extract_name(fn)
                        fn_id = FunctionCompiler.logical_id_for(fn_name)
                        ['AWS/Lambda', metric_name, 'FunctionName', "${#{fn_id}}"]
                      end
                    end

          period = widget.period || dashboard.period || 300

          {
            'type' => 'metric',
            'x' => widget.x,
            'y' => widget.y,
            'width' => widget.width,
            'height' => widget.height,
            'properties' => {
              'view' => 'timeSeries',
              'stacked' => false,
              'metrics' => metrics,
              'region' => '${AWS::Region}',
              'title' => widget.title,
              'period' => period,
              'stat' => widget.stat
            }
          }
        end

        def normalize_metric(metric)
          key = metric.to_s.downcase
          KNOWN_METRICS[key] || LogicalId.pascalize(metric)
        end

        def extract_name(item)
          if item.respond_to?(:logical_name)
            item.logical_name
          elsif item.respond_to?(:symbolic_name)
            item.symbolic_name
          elsif item.respond_to?(:name)
            item.name
          elsif item.is_a?(Hash)
            item[:logical_name] || item['logical_name'] ||
              item[:symbolic_name] || item['symbolic_name'] ||
              item[:name] || item['name']
          else
            item.to_s
          end
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.keys.sort_by(&:to_s).to_h do |k|
              [k.to_s, deep_sort_keys(obj[k])]
            end
          when Array
            obj.map { |v| deep_sort_keys(v) }
          else
            obj
          end
        end

        def freeze_hash(hash)
          hash.each_with_object({}) do |(k, v), memo|
            frozen_val = v.is_a?(Hash) ? freeze_hash(v) : v.to_s.freeze
            memo[k.to_s.freeze] = frozen_val
          end.freeze
        end
      end
    end
  end
end
