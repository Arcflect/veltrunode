# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/access_point_compiler'
require 'veltrunode/model/managed_access_point'
require 'veltrunode/model/efs_mount'

RSpec.describe Veltrunode::Compiler::CloudFormation::AccessPointCompiler do
  let(:valid_fs_id) { 'fs-0123456789abcdef0' }
  let(:managed_ap) do
    Veltrunode::Model::ManagedAccessPoint.new(
      file_system_id: valid_fs_id,
      root_directory_path: '/export/lambda',
      posix_user: { uid: 1000, gid: 1000, secondary_gids: [1001, 1002] },
      creation_info: { owner_uid: 1000, owner_gid: 1000, permissions: '0755' },
      tags: { 'Environment' => 'test', 'Project' => 'demo' }
    )
  end

  let(:mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      local_path: '/mnt/shared',
      managed_access_point: managed_ap
    )
  end

  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for EFS Access Points' do
      expect(described_class.logical_id_for('shared_data')).to eq('SharedDataAccessPoint')
      expect(described_class.logical_id_for('shared_data_access_point')).to eq('SharedDataAccessPoint')
      expect(described_class.logical_id_for('app_efs')).to eq('AppEfsAccessPoint')
      expect(described_class.logical_id_for('')).to eq('AccessPoint')
    end
  end

  describe '#to_h and properties' do
    it 'compiles an AWS::EFS::AccessPoint resource with all configured properties' do
      result = described_class.compile(mount)

      expect(result).to have_key('SharedDataAccessPoint')
      resource = result['SharedDataAccessPoint']
      expect(resource['Type']).to eq('AWS::EFS::AccessPoint')

      props = resource['Properties']
      expect(props['FileSystemId']).to eq(valid_fs_id)
      expect(props['PosixUser']).to eq(
        {
          'Gid' => '1000',
          'SecondaryGids' => %w[1001 1002],
          'Uid' => '1000'
        }
      )
      expect(props['RootDirectory']).to eq(
        {
          'CreationInfo' => {
            'OwnerGid' => '1000',
            'OwnerUid' => '1000',
            'Permissions' => '0755'
          },
          'Path' => '/export/lambda'
        }
      )
      expect(props['AccessPointTags']).to eq(
        [
          { 'Key' => 'Environment', 'Value' => 'test' },
          { 'Key' => 'Project', 'Value' => 'demo' }
        ]
      )
    end

    it 'compiles a minimal managed access point with default root directory' do
      minimal_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'minimal_data',
        local_path: '/mnt/data',
        managed_access_point: { file_system_id: valid_fs_id }
      )

      result = described_class.compile(minimal_mount)
      props = result['MinimalDataAccessPoint']['Properties']

      expect(props['FileSystemId']).to eq(valid_fs_id)
      expect(props['RootDirectory']).to eq({ 'Path' => '/' })
      expect(props).not_to have_key('PosixUser')
      expect(props).not_to have_key('AccessPointTags')
    end

    it 'raises ValidationError when compile is invoked on an unmanaged mount' do
      unmanaged = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'unmanaged_data',
        local_path: '/mnt/data',
        access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-0123456789abcdef0'
      )

      expect do
        described_class.compile(unmanaged)
      end.to raise_error(Veltrunode::ValidationError, /does not have managed_access_point configuration/)
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(mount)
      keys = result['SharedDataAccessPoint']['Properties'].keys
      expect(keys).to eq(keys.sort)
    end

    it 'generates valid YAML string' do
      yaml_str = described_class.new(mount).to_yaml
      loaded = YAML.safe_load(yaml_str)
      expect(loaded).to have_key('SharedDataAccessPoint')
      expect(loaded['SharedDataAccessPoint']['Type']).to eq('AWS::EFS::AccessPoint')
    end
  end
end
