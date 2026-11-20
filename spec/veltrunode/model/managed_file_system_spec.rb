# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::ManagedFileSystem do
  describe '#initialize and validation' do
    it 'initializes with vpc_id, subnet_ids, and default Retain deletion policies' do
      mfs = described_class.new(
        symbolic_name: :shared_storage,
        vpc_id: 'vpc-0123456789abcdef0',
        subnet_ids: %w[subnet-11112222 subnet-33334444],
        throughput_mode: :elastic,
        encrypted: true
      )

      expect(mfs.symbolic_name).to eq('shared_storage')
      expect(mfs.vpc_id).to eq('vpc-0123456789abcdef0')
      expect(mfs.subnet_ids).to eq(%w[subnet-11112222 subnet-33334444])
      expect(mfs.deletion_policy).to eq('Retain')
      expect(mfs.update_replace_policy).to eq('Retain')
      expect(mfs.deletion_protection?).to be(true)
      expect(mfs.throughput_mode).to eq('elastic')
      expect(mfs.encrypted?).to be(true)
      expect(mfs).to be_frozen
    end

    it 'accepts DSL::Reference and Symbol for vpc_id and subnet_ids' do
      vpc_ref = Veltrunode::DSL::Reference.new(:vpc_id)
      sub_ref = Veltrunode::DSL::Reference.new(:private_subnet_a)
      mfs = described_class.new(
        symbolic_name: :ref_storage,
        vpc_id: vpc_ref,
        subnets: [sub_ref, :private_subnet_b]
      )

      expect(mfs.vpc_id).to eq(vpc_ref)
      expect(mfs.subnets).to eq([sub_ref, :private_subnet_b])
    end

    it 'supports custom deletion_policy, update_replace_policy, and deletion_protection: false' do
      mfs_del = described_class.new(
        symbolic_name: :ephemeral_storage,
        vpc_id: 'vpc-0123456789abcdef0',
        subnet_ids: ['subnet-11112222'],
        deletion_protection: false
      )
      expect(mfs_del.deletion_policy).to eq('Delete')
      expect(mfs_del.update_replace_policy).to eq('Delete')
      expect(mfs_del.deletion_protection?).to be(false)

      mfs_custom = described_class.new(
        symbolic_name: :snapshot_storage,
        vpc_id: 'vpc-0123456789abcdef0',
        subnet_ids: ['subnet-11112222'],
        deletion_policy: :retain_except_on_create,
        update_replace_policy: :snapshot
      )
      expect(mfs_custom.deletion_policy).to eq('RetainExceptOnCreate')
      expect(mfs_custom.update_replace_policy).to eq('Snapshot')
    end

    it 'raises ValidationError when subnet_ids is empty/invalid or vpc_id and security_group_ids are missing' do
      expect do
        described_class.new(symbolic_name: :bad, vpc_id: 'vpc-0123456789abcdef0', subnet_ids: [])
      end.to raise_error(Veltrunode::ValidationError, /subnet_ids is required/)

      expect do
        described_class.new(symbolic_name: :bad, vpc_id: 'vpc-0123456789abcdef0', subnet_ids: ['invalid-subnet'])
      end.to raise_error(Veltrunode::ValidationError, /Invalid ManagedFileSystem subnet_id/)

      expect do
        described_class.new(symbolic_name: :bad, vpc_id: 'invalid-vpc', subnet_ids: ['subnet-11112222'])
      end.to raise_error(Veltrunode::ValidationError, /Invalid ManagedFileSystem vpc_id/)

      expect do
        described_class.new(symbolic_name: :bad, subnet_ids: ['subnet-11112222'])
      end.to raise_error(Veltrunode::ValidationError, /requires vpc_id .* or explicit security_group_ids/)

      expect do
        described_class.new(
          symbolic_name: :bad,
          vpc_id: 'vpc-0123456789abcdef0',
          subnet_ids: ['subnet-11112222'],
          deletion_policy: :invalid
        )
      end.to raise_error(Veltrunode::ValidationError, /Invalid ManagedFileSystem deletion_policy/)
    end
  end
end
