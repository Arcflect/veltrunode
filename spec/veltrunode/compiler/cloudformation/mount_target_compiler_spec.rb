# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/mount_target_compiler'
require 'veltrunode/model/efs_mount'

RSpec.describe Veltrunode::Compiler::CloudFormation::MountTargetCompiler do
  let(:mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_storage',
      vpc_id: 'vpc-0123456789abcdef0',
      subnet_ids: %w[subnet-11112222 subnet-33334444]
    )
  end

  describe '.logical_id_for and .logical_ids_for' do
    it 'generates deterministic PascalCase logical IDs for EFS MountTargets per subnet' do
      expect(described_class.logical_id_for('shared_storage', 'subnet-11112222'))
        .to eq('SharedStorageSubnet11112222MountTarget')
      expect(described_class.logical_id_for('shared_storage', :private_subnet_a))
        .to eq('SharedStoragePrivateSubnetAMountTarget')
      expect(described_class.logical_ids_for(mount)).to eq(
        %w[
          SharedStorageSubnet11112222MountTarget
          SharedStorageSubnet33334444MountTarget
        ]
      )
    end
  end

  describe '#to_h and .compile' do
    it 'compiles AWS::EFS::MountTarget resources for each subnet referencing FileSystem and EFS SecurityGroup' do
      result = described_class.compile(mount)

      expect(result.keys).to contain_exactly(
        'SharedStorageSubnet11112222MountTarget',
        'SharedStorageSubnet33334444MountTarget'
      )

      mt1 = result['SharedStorageSubnet11112222MountTarget']
      expect(mt1['Type']).to eq('AWS::EFS::MountTarget')
      expect(mt1['Properties']).to eq(
        'FileSystemId' => { 'Ref' => 'SharedStorageFileSystem' },
        'SecurityGroups' => [{ 'Ref' => 'SharedStorageEfsSecurityGroup' }],
        'SubnetId' => 'subnet-11112222'
      )

      mt2 = result['SharedStorageSubnet33334444MountTarget']
      expect(mt2['Type']).to eq('AWS::EFS::MountTarget')
      expect(mt2['Properties']).to eq(
        'FileSystemId' => { 'Ref' => 'SharedStorageFileSystem' },
        'SecurityGroups' => [{ 'Ref' => 'SharedStorageEfsSecurityGroup' }],
        'SubnetId' => 'subnet-33334444'
      )
    end

    it 'supports parameter references for subnets and explicit security_group_ids' do
      ref_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'custom_fs',
        subnet_ids: [Veltrunode::DSL::Reference.new(:subnet_a)],
        security_group_ids: ['sg-99998888']
      )

      result = described_class.compile(ref_mount)
      mt = result['CustomFsSubnetAMountTarget']
      expect(mt['Properties']).to eq(
        'FileSystemId' => { 'Ref' => 'CustomFsFileSystem' },
        'SecurityGroups' => ['sg-99998888'],
        'SubnetId' => { 'Ref' => 'SubnetA' }
      )
    end
  end
end
