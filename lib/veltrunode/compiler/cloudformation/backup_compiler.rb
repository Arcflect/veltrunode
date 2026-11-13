# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'role_compiler'
require_relative '../../model/managed_access_point'

module Veltrunode
  module Compiler
    module CloudFormation
      # EFS 自動バックアップ用 AWS Backup リソース群 (BackupVault, BackupPlan, BackupSelection, IAM Role) のコンパイラ
      class BackupCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def vault_logical_id_for(name)
            LogicalId.for_backup_vault(name)
          end

          def plan_logical_id_for(name)
            LogicalId.for_backup_plan(name)
          end

          def selection_logical_id_for(name)
            LogicalId.for_backup_selection(name)
          end

          def role_logical_id_for(name)
            LogicalId.for_backup_role(name)
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

        def vault_logical_id
          self.class.vault_logical_id_for(mount_name)
        end

        def plan_logical_id
          self.class.plan_logical_id_for(mount_name)
        end

        def selection_logical_id
          self.class.selection_logical_id_for(mount_name)
        end

        def role_logical_id
          self.class.role_logical_id_for(mount_name)
        end

        def file_system_logical_id
          self.class.file_system_logical_id_for(mount_name)
        end

        def to_h
          config = resolved_backup_config
          return {} if config.nil? || config.empty?

          resources = {
            vault_logical_id => {
              'Type' => 'AWS::Backup::BackupVault',
              'Properties' => vault_properties(config)
            },
            plan_logical_id => {
              'Type' => 'AWS::Backup::BackupPlan',
              'Properties' => plan_properties(config)
            },
            selection_logical_id => {
              'Type' => 'AWS::Backup::BackupSelection',
              'Properties' => selection_properties
            }
          }
          resources.merge!(RoleCompiler.compile_backup_role(mount_name, context: context))

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def vault_properties(config = resolved_backup_config)
          custom_vault_name = config && (config['vault_name'] || config[:vault_name])
          {
            'BackupVaultName' => custom_vault_name || { 'Fn::Sub' => "${AWS::StackName}-#{vault_logical_id}" }
          }
        end

        def plan_properties(config = resolved_backup_config)
          schedule = (config && (config['schedule'] || config[:schedule])) ||
                     Model::ManagedAccessPoint::DEFAULT_BACKUP_SCHEDULE
          retention_days = (config && (config['retention_days'] || config[:retention_days])) ||
                           Model::ManagedAccessPoint::DEFAULT_BACKUP_RETENTION_DAYS
          cold_days = config && (config['cold_storage_after_days'] || config[:cold_storage_after_days])
          custom_plan_name = config && (config['plan_name'] || config[:plan_name])
          custom_rule_name = (config && (config['rule_name'] || config[:rule_name])) || 'DailyBackupRule'

          lifecycle = {
            'DeleteAfterDays' => retention_days
          }
          lifecycle['MoveToColdStorageAfterDays'] = cold_days if cold_days

          {
            'BackupPlan' => {
              'BackupPlanName' => custom_plan_name || { 'Fn::Sub' => "${AWS::StackName}-#{plan_logical_id}" },
              'BackupPlanRule' => [
                {
                  'Lifecycle' => lifecycle,
                  'RuleName' => custom_rule_name,
                  'ScheduleExpression' => schedule,
                  'TargetBackupVault' => { 'Ref' => vault_logical_id }
                }
              ]
            }
          }
        end

        def selection_properties
          {
            'BackupPlanId' => { 'Ref' => plan_logical_id },
            'BackupSelection' => {
              'IamRoleArn' => { 'Fn::GetAtt' => [role_logical_id, 'Arn'] },
              'Resources' => [resolve_target_resource_arn],
              'SelectionName' => { 'Fn::Sub' => "${AWS::StackName}-#{selection_logical_id}" }
            }
          }
        end

        private

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

        def resolved_backup_config
          raw = extract_raw_backup
          return nil if raw == false

          Model::ManagedAccessPoint.normalize_backup_config(raw || true)
        end

        def extract_raw_backup
          if mount.respond_to?(:backup) && !mount.backup.nil?
            mount.backup
          elsif mount.respond_to?(:managed_access_point) && !mount.managed_access_point&.backup.nil?
            mount.managed_access_point.backup
          elsif mount.is_a?(Hash)
            return mount[:backup] if mount.key?(:backup)
            return mount['backup'] if mount.key?('backup')

            ap = mount[:managed_access_point] || mount['managed_access_point']
            if ap.respond_to?(:backup)
              ap.backup
            elsif ap.is_a?(Hash)
              ap[:backup] || ap['backup']
            end
          end
        end

        def resolve_target_resource_arn
          fs_id = extract_file_system_id
          has_fs_res = managed_file_system_resource?

          if fs_id.is_a?(String)
            str = fs_id.strip
            return str if str.start_with?('arn:')

            if !has_fs_res && Model::ManagedAccessPoint::FILE_SYSTEM_ID_PATTERN.match?(str)
              return {
                'Fn::Sub' => "arn:aws:elasticfilesystem:${AWS::Region}:${AWS::AccountId}:file-system/#{str}"
              }
            end
          elsif fs_id.is_a?(Hash)
            ref_target = fs_id['Ref'] || fs_id[:Ref]
            return { 'Fn::GetAtt' => [ref_target.to_s, 'Arn'] } if ref_target
          end

          { 'Fn::GetAtt' => [file_system_logical_id, 'Arn'] }
        end

        def extract_file_system_id
          if mount.respond_to?(:file_system_id) && mount.file_system_id
            mount.file_system_id
          elsif mount.respond_to?(:managed_access_point) && mount.managed_access_point&.file_system_id
            mount.managed_access_point.file_system_id
          elsif mount.is_a?(Hash)
            ap = mount[:managed_access_point] || mount['managed_access_point']
            if ap.respond_to?(:file_system_id)
              ap.file_system_id
            elsif ap.is_a?(Hash)
              ap[:file_system_id] || ap['file_system_id']
            else
              mount[:file_system_id] || mount['file_system_id']
            end
          end
        end

        def managed_file_system_resource?
          return true if mount.respond_to?(:file_system_configuration?) && mount.file_system_configuration?

          if mount.respond_to?(:managed_access_point) && mount.managed_access_point
            map = mount.managed_access_point
            return true if map.respond_to?(:file_system_configuration?) && map.file_system_configuration?
          end

          false
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
