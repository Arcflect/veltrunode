# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/replication_compiler'
require 'veltrunode/model/efs_mount'

RSpec.describe Veltrunode::Compiler::CloudFormation::ReplicationCompiler do
  let(:dest_kms_arn) { 'arn:aws:kms:us-west-2:123456789012:key/12345678-1234-1234-1234-123456789012' }

  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for EFS ReplicationConfiguration' do
      expect(described_class.logical_id_for('shared_data')).to eq('SharedDataReplicationConfiguration')
      expect(described_class.logical_id_for('shared_data_replication_configuration'))
        .to eq('SharedDataReplicationConfiguration')
      expect(described_class.logical_id_for('')).to eq('ReplicationConfiguration')
    end
  end

  describe '#to_h and .compile' do
    it 'compiles AWS::EFS::ReplicationConfiguration with Region and KmsKeyId for a managed file system' do
      mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'dr_storage',
        local_path: '/mnt/dr',
        replication: {
          destination_region: 'us-west-2',
          kms_key_id: dest_kms_arn
        }
      )

      result = described_class.compile(mount)
      expect(result).to have_key('DrStorageReplicationConfiguration')

      rep = result['DrStorageReplicationConfiguration']
      expect(rep['Type']).to eq('AWS::EFS::ReplicationConfiguration')
      expect(rep['Properties']).to eq(
        'Destinations' => [
          {
            'KmsKeyId' => dest_kms_arn,
            'Region' => 'us-west-2'
          }
        ],
        'SourceFileSystemId' => { 'Ref' => 'DrStorageFileSystem' }
      )
    end

    it 'compiles AWS::EFS::ReplicationConfiguration with literal SourceFileSystemId and Ref KmsKeyId' do
      mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'existing_fs_dr',
        local_path: '/mnt/existing_dr',
        managed_access_point: {
          file_system_id: 'fs-0123456789abcdef0',
          replication: {
            destination_region: 'us-east-1',
            kms_key_id: Veltrunode::DSL::Reference.new(:dr_kms_key)
          }
        }
      )

      result = described_class.compile(mount)
      rep = result['ExistingFsDrReplicationConfiguration']
      expect(rep['Properties']).to eq(
        'Destinations' => [
          {
            'KmsKeyId' => { 'Ref' => 'DrKmsKey' },
            'Region' => 'us-east-1'
          }
        ],
        'SourceFileSystemId' => 'fs-0123456789abcdef0'
      )
    end
  end
end
