# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative '../../model/managed_access_point'

module Veltrunode
  module Compiler
    module CloudFormation
      # EFS メトリクス監視用 CloudWatch アラーム (BurstCreditBalance / PercentIOLimit) のコンパイラ
      class EfsAlarmCompiler
        METRIC_KEYS = %w[burst_credit_balance percent_io_limit].freeze

        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(name, metric = :burst_credit_balance)
            LogicalId.for_efs_alarm(name, metric)
          end

          def burst_credit_alarm_logical_id_for(name)
            LogicalId.for_efs_alarm(name, :burst_credit_balance)
          end

          def percent_io_limit_alarm_logical_id_for(name)
            LogicalId.for_efs_alarm(name, :percent_io_limit)
          end

          def file_system_logical_id_for(name)
            LogicalId.for_file_system(name)
          end

          def pascalize(str)
            LogicalId.pascalize(str)
          end
        end

        def initialize(mount, options: {}, context: {})
          @mount = mount
          @options = freeze_hash(options)
          @context = freeze_hash(context)
        end

        def file_system_logical_id
          self.class.file_system_logical_id_for(mount_name)
        end

        def resource_type
          'AWS::CloudWatch::Alarm'
        end

        def to_h
          config = resolved_alarms_config
          return {} if config.nil? || config.empty?

          resources = {}
          METRIC_KEYS.each do |metric_key|
            entry = config[metric_key] || config[metric_key.to_sym]
            next unless entry.is_a?(Hash)

            alarm_id = self.class.logical_id_for(mount_name, metric_key)
            resources[alarm_id] = {
              'Type' => resource_type,
              'Properties' => build_alarm_properties(alarm_id, entry)
            }
          end

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def build_alarm_properties(alarm_id, entry)
          metric_name = (entry['metric_name'] || entry[:metric_name]).to_s
          props = {
            'AlarmDescription' => "CloudWatch Alarm for EFS #{mount_name} #{metric_name}",
            'AlarmName' => { 'Fn::Sub' => "${AWS::StackName}-#{alarm_id}" },
            'ComparisonOperator' => (entry['comparison_operator'] || entry[:comparison_operator]).to_s,
            'Dimensions' => [
              {
                'Name' => 'FileSystemId',
                'Value' => resolve_file_system_id
              }
            ],
            'EvaluationPeriods' => entry['evaluation_periods'] || entry[:evaluation_periods] || 1,
            'MetricName' => metric_name,
            'Namespace' => 'AWS/EFS',
            'Period' => entry['period'] || entry[:period] || 300,
            'Statistic' => (entry['statistic'] || entry[:statistic]).to_s,
            'Threshold' => entry['threshold'] || entry[:threshold],
            'TreatMissingData' => (entry['treat_missing_data'] || entry[:treat_missing_data] || 'notBreaching').to_s
          }

          alarm_actions = format_actions(entry['alarm_actions'] || entry[:alarm_actions])
          props['AlarmActions'] = alarm_actions unless alarm_actions.empty?

          ok_actions = format_actions(entry['ok_actions'] || entry[:ok_actions])
          props['OKActions'] = ok_actions unless ok_actions.empty?

          props
        end

        def mount_name
          if mount.respond_to?(:symbolic_name)
            mount.symbolic_name
          elsif mount.respond_to?(:name)
            mount.name
          elsif mount.is_a?(Hash)
            mount[:symbolic_name] || mount['symbolic_name'] || mount[:name] || mount['name']
          else
            mount.to_s
          end
        end

        def resolved_alarms_config
          raw = extract_raw_alarms
          return nil if raw == false
          if raw.is_a?(Hash) && (raw['burst_credit_balance'].is_a?(Hash) || raw['percent_io_limit'].is_a?(Hash))
            return raw
          end

          Model::ManagedAccessPoint.normalize_alarms_config(raw || true)
        end

        def extract_raw_alarms
          if mount.respond_to?(:alarms) && !mount.alarms.nil?
            mount.alarms
          elsif mount.respond_to?(:managed_access_point) && !mount.managed_access_point&.alarms.nil?
            mount.managed_access_point.alarms
          elsif mount.is_a?(Hash)
            return mount[:alarms] if mount.key?(:alarms)
            return mount['alarms'] if mount.key?('alarms')

            ap = mount[:managed_access_point] || mount['managed_access_point']
            if ap.respond_to?(:alarms)
              ap.alarms
            elsif ap.is_a?(Hash)
              ap[:alarms] || ap['alarms']
            end
          end
        end

        def resolve_file_system_id
          fs_id = extract_file_system_id
          has_fs_res = managed_file_system_resource?

          if fs_id.is_a?(String)
            str = fs_id.strip
            return str if !has_fs_res && Model::ManagedAccessPoint::FILE_SYSTEM_ID_PATTERN.match?(str)
          elsif fs_id.is_a?(Hash)
            return fs_id
          elsif fs_id.respond_to?(:name)
            return { 'Ref' => LogicalId.pascalize(fs_id.name) }
          end

          { 'Ref' => file_system_logical_id }
        end

        def extract_file_system_id
          if mount.respond_to?(:managed_access_point) && mount.managed_access_point&.file_system_id
            mount.managed_access_point.file_system_id
          elsif mount.respond_to?(:file_system_id) && mount.file_system_id
            mount.file_system_id
          elsif mount.is_a?(Hash)
            direct = mount[:file_system_id] || mount['file_system_id']
            return direct if direct

            ap = mount[:managed_access_point] || mount['managed_access_point']
            if ap.respond_to?(:file_system_id)
              ap.file_system_id
            elsif ap.is_a?(Hash)
              ap[:file_system_id] || ap['file_system_id']
            end
          end
        end

        def managed_file_system_resource?
          return true if mount.respond_to?(:file_system_configuration?) && mount.file_system_configuration?
          return true if mount.respond_to?(:lifecycle_policies?) && mount.lifecycle_policies?
          return true if mount.respond_to?(:throughput_configuration?) && mount.throughput_configuration?

          false
        end

        def format_actions(actions)
          Array(actions).compact.map { |act| format_action(act) }.compact
        end

        def format_action(action)
          return action if action.is_a?(Hash)
          return { 'Ref' => LogicalId.pascalize(action.name) } if action.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(action) } if action.is_a?(Symbol)

          str = action.to_s.strip
          return nil if str.empty?

          if str.start_with?('arn:aws:')
            str
          else
            { 'Ref' => str }
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
          (hash || {}).dup.freeze
        end
      end
    end
  end
end
