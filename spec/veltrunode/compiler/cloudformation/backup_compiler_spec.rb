# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/backup_compiler'
require 'veltrunode/model/managed_access_point'
require 'veltrunode/model/efs_mount'

RSpec.describe Veltrunode::Compiler::CloudFormation::BackupCompiler do
  let(:mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      local_path: '/mnt/shared',
      managed_access_point: {
        file_system_id: 'fs-0123456789abcdef0',
        backup: {
          schedule: 'cron(0 12 * * ? *)',
          retention_days: 30
        }
      }
    )
  end

  describe 'logical ID helpers' do
    it 'generates stable PascalCase logical IDs for BackupVault, BackupPlan, BackupSelection, and BackupRole' do
      expect(described_class.vault_logical_id_for('shared_data')).to eq('SharedDataBackupVault')
      expect(described_class.plan_logical_id_for('shared_data')).to eq('SharedDataBackupPlan')
      expect(described_class.selection_logical_id_for('shared_data')).to eq('SharedDataBackupSelection')
      expect(described_class.role_logical_id_for('shared_data')).to eq('SharedDataBackupRole')
    end
  end

  describe '#to_h' do
    it 'compiles BackupVault, BackupPlan, BackupSelection, and AWS Backup IAM Service Role' do
      result = described_class.compile(mount)

      expect(result.keys).to contain_exactly(
        'SharedDataBackupPlan',
        'SharedDataBackupRole',
        'SharedDataBackupSelection',
        'SharedDataBackupVault'
      )

      vault = result['SharedDataBackupVault']
      expect(vault['Type']).to eq('AWS::Backup::BackupVault')
      expect(vault['Properties']['BackupVaultName']).to eq(
        'Fn::Sub' => '${AWS::StackName}-SharedDataBackupVault'
      )

      plan = result['SharedDataBackupPlan']
      expect(plan['Type']).to eq('AWS::Backup::BackupPlan')
      expect(plan['Properties']['BackupPlan']).to eq(
        'BackupPlanName' => { 'Fn::Sub' => '${AWS::StackName}-SharedDataBackupPlan' },
        'BackupPlanRule' => [
          {
            'Lifecycle' => { 'DeleteAfterDays' => 30 },
            'RuleName' => 'DailyBackupRule',
            'ScheduleExpression' => 'cron(0 12 * * ? *)',
            'TargetBackupVault' => { 'Ref' => 'SharedDataBackupVault' }
          }
        ]
      )

      role = result['SharedDataBackupRole']
      expect(role['Type']).to eq('AWS::IAM::Role')
      expect(role['Properties']['AssumeRolePolicyDocument']['Statement']).to eq(
        [
          {
            'Action' => 'sts:AssumeRole',
            'Effect' => 'Allow',
            'Principal' => { 'Service' => 'backup.amazonaws.com' }
          }
        ]
      )
      expect(role['Properties']['ManagedPolicyArns']).to eq(
        [
          'arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup',
          'arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores'
        ]
      )

      selection = result['SharedDataBackupSelection']
      expect(selection['Type']).to eq('AWS::Backup::BackupSelection')
      expect(selection['Properties']).to eq(
        'BackupPlanId' => { 'Ref' => 'SharedDataBackupPlan' },
        'BackupSelection' => {
          'IamRoleArn' => { 'Fn::GetAtt' => %w[SharedDataBackupRole Arn] },
          'Resources' => [
            {
              'Fn::Sub' => 'arn:aws:elasticfilesystem:${AWS::Region}:${AWS::AccountId}:file-system/fs-0123456789abcdef0'
            }
          ],
          'SelectionName' => { 'Fn::Sub' => '${AWS::StackName}-SharedDataBackupSelection' }
        }
      )
    end

    it 'references generated FileSystem Arn when file_system_id is omitted (managed FileSystem)' do
      managed_fs_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'stateful_efs',
        local_path: '/mnt/stateful',
        backup: true
      )

      result = described_class.compile(managed_fs_mount)
      selection = result['StatefulEfsBackupSelection']
      expect(selection['Properties']['BackupSelection']['Resources']).to eq(
        [{ 'Fn::GetAtt' => %w[StatefulEfsFileSystem Arn] }]
      )
    end

    it 'supports custom vault_name, plan_name, rule_name, and cold_storage_after_days' do
      custom_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'archive_efs',
        local_path: '/mnt/archive',
        managed_access_point: {
          file_system_id: 'fs-0123456789abcdef0',
          backup: {
            schedule: 'cron(0 3 * * ? *)',
            retention_days: 90,
            cold_storage_after_days: 14,
            vault_name: 'custom-efs-vault',
            plan_name: 'custom-efs-plan',
            rule_name: 'NightlyBackupRule'
          }
        }
      )

      result = described_class.compile(custom_mount)
      expect(result['ArchiveEfsBackupVault']['Properties']['BackupVaultName']).to eq('custom-efs-vault')

      plan_props = result['ArchiveEfsBackupPlan']['Properties']['BackupPlan']
      expect(plan_props['BackupPlanName']).to eq('custom-efs-plan')
      rule = plan_props['BackupPlanRule'].first
      expect(rule['RuleName']).to eq('NightlyBackupRule')
      expect(rule['ScheduleExpression']).to eq('cron(0 3 * * ? *)')
      expect(rule['Lifecycle']).to eq(
        'DeleteAfterDays' => 90,
        'MoveToColdStorageAfterDays' => 14
      )
    end

    it 'generates valid YAML string' do
      yaml_str = described_class.to_yaml(mount)
      loaded = YAML.safe_load(yaml_str)
      expect(loaded).to have_key('SharedDataBackupVault')
      expect(loaded).to have_key('SharedDataBackupPlan')
      expect(loaded).to have_key('SharedDataBackupSelection')
      expect(loaded).to have_key('SharedDataBackupRole')
    end
  end
end
