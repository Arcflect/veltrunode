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

    it 'compiles ThroughputMode and ProvisionedThroughputInMibps when configured' do
      prov_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'high_throughput_efs',
        local_path: '/mnt/high',
        throughput_mode: :provisioned,
        provisioned_throughput_in_mibps: 500
      )

      result = described_class.compile(prov_mount)
      props = result['HighThroughputEfsFileSystem']['Properties']
      expect(props['ThroughputMode']).to eq('provisioned')
      expect(props['ProvisionedThroughputInMibps']).to eq(500)
    end

    it 'compiles Encrypted and KmsKeyId for customer-managed KMS key ARN and Ref' do
      kms_arn = 'arn:aws:kms:ap-northeast-1:123456789012:key/12345678-1234-1234-1234-123456789012'
      cmk_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'cmk_efs',
        local_path: '/mnt/cmk',
        encrypted: true,
        kms_key_id: kms_arn
      )

      result = described_class.compile(cmk_mount)
      props = result['CmkEfsFileSystem']['Properties']
      expect(props['Encrypted']).to be(true)
      expect(props['KmsKeyId']).to eq(kms_arn)

      ref_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'ref_cmk_efs',
        local_path: '/mnt/ref_cmk',
        kms_key_id: Veltrunode::DSL::Reference.new(:custom_efs_kms_key)
      )

      ref_result = described_class.compile(ref_mount)
      ref_props = ref_result['RefCmkEfsFileSystem']['Properties']
      expect(ref_props['Encrypted']).to be(true)
      expect(ref_props['KmsKeyId']).to eq({ 'Ref' => 'CustomEfsKmsKey' })
    end
  end
end
