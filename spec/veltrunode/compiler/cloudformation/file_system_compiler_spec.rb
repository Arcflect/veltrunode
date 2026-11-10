# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/file_system_compiler'
require 'veltrunode/model/managed_access_point'
require 'veltrunode/model/efs_mount'

RSpec.describe Veltrunode::Compiler::CloudFormation::FileSystemCompiler do
  let(:mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_logs',
      local_path: '/mnt/logs',
      managed_access_point: {
        file_system_id: 'fs-0123456789abcdef0',
        lifecycle_policies: {
          transition_to_ia: 'AFTER_30_DAYS',
          transition_to_archive: 'AFTER_90_DAYS'
        }
      }
    )
  end

  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for EFS FileSystems' do
      expect(described_class.logical_id_for('shared_logs')).to eq('SharedLogsFileSystem')
      expect(described_class.logical_id_for('shared_logs_file_system')).to eq('SharedLogsFileSystem')
      expect(described_class.logical_id_for('')).to eq('FileSystem')
    end
  end

  describe '#to_h and properties' do
    it 'compiles an AWS::EFS::FileSystem resource with LifecyclePolicies' do
      result = described_class.compile(mount)

      expect(result).to have_key('SharedLogsFileSystem')
      resource = result['SharedLogsFileSystem']
      expect(resource['Type']).to eq('AWS::EFS::FileSystem')
      expect(resource['Properties']['LifecyclePolicies']).to eq(
        [
          { 'TransitionToIA' => 'AFTER_30_DAYS' },
          { 'TransitionToArchive' => 'AFTER_90_DAYS' }
        ]
      )
    end

    it 'generates valid YAML string' do
      yaml_str = described_class.to_yaml(mount)
      loaded = YAML.safe_load(yaml_str)
      expect(loaded).to have_key('SharedLogsFileSystem')
      expect(loaded['SharedLogsFileSystem']['Type']).to eq('AWS::EFS::FileSystem')
    end
  end
end
