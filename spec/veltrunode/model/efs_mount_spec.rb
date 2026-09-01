# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::EfsMount do
  let(:valid_arn) { 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-0123456789abcdef0' }
  let(:valid_attributes) do
    {
      symbolic_name: 'shared_data',
      access_point_source: valid_arn,
      local_path: '/mnt/shared',
      vpc_expectations: { security_group_id: 'sg-12345' },
      posix_expectations: { uid: 1000, gid: 1000 },
      diagnostic_policy: { strict: true }
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:mount) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(mount.symbolic_name).to eq('shared_data')
        expect(mount.access_point_source).to eq(valid_arn)
        expect(mount.local_path).to eq('/mnt/shared')
        expect(mount.vpc_expectations).to eq({ 'security_group_id' => 'sg-12345' })
        expect(mount.posix_expectations).to eq({ 'uid' => 1000, 'gid' => 1000 })
        expect(mount.diagnostic_policy).to eq({ 'strict' => true })
      end

      it 'provides default values for optional attributes' do
        minimal = described_class.new(
          symbolic_name: 'data',
          access_point_source: 'my_ap',
          local_path: '/mnt/data'
        )

        expect(minimal.vpc_expectations).to eq({})
        expect(minimal.posix_expectations).to eq({})
        expect(minimal.diagnostic_policy).to eq({})
      end
    end

    context 'immutability' do
      subject(:mount) { described_class.new(**valid_attributes) }

      it 'freezes the instance and attributes' do
        expect(mount).to be_frozen
        expect(mount.symbolic_name).to be_frozen
        expect(mount.access_point_source).to be_frozen
        expect(mount.local_path).to be_frozen
        expect(mount.vpc_expectations).to be_frozen
        expect(mount.posix_expectations).to be_frozen
        expect(mount.diagnostic_policy).to be_frozen
      end

      it 'prevents modification of attributes' do
        expect { mount.vpc_expectations['sg'] = 'val' }.to raise_error(FrozenError)
      end
    end

    context 'local_path validation' do
      it 'allows local_path starting with /mnt/' do
        m1 = described_class.new(symbolic_name: 'm1', access_point_source: 'ap', local_path: '/mnt/efs')
        m2 = described_class.new(symbolic_name: 'm2', access_point_source: 'ap', local_path: '/mnt/shared/logs')

        expect(m1.local_path).to eq('/mnt/efs')
        expect(m2.local_path).to eq('/mnt/shared/logs')
      end

      it 'raises ValidationError when local_path does not start with /mnt/' do
        expect do
          described_class.new(symbolic_name: 'm', access_point_source: 'ap', local_path: '/tmp/data')
        end.to raise_error(Veltrunode::ValidationError, %r{/mnt/})

        expect do
          described_class.new(symbolic_name: 'm', access_point_source: 'ap', local_path: 'mnt/data')
        end.to raise_error(Veltrunode::ValidationError, %r{/mnt/})
      end

      it 'raises ValidationError when local_path is missing or empty' do
        expect do
          described_class.new(symbolic_name: 'm', access_point_source: 'ap', local_path: nil)
        end.to raise_error(Veltrunode::ValidationError, /local_path/)

        expect do
          described_class.new(symbolic_name: 'm', access_point_source: 'ap', local_path: '')
        end.to raise_error(Veltrunode::ValidationError, /local_path/)
      end
    end

    context 'access_point_source validation' do
      it 'allows valid EFS access point ARNs and logical reference names' do
        m1 = described_class.new(symbolic_name: 'm1', access_point_source: valid_arn, local_path: '/mnt/a')
        m2 = described_class.new(symbolic_name: 'm2', access_point_source: 'logical_ap_name', local_path: '/mnt/b')

        expect(m1.access_point_source).to eq(valid_arn)
        expect(m2.access_point_source).to eq('logical_ap_name')
      end

      it 'allows Hash access_point_source for CloudFormation parameters and import references' do
        ref_source = { 'Ref' => 'EfsAccessPointParam' }
        import_source = { 'Fn::ImportValue' => 'ExportedAccessPointArn' }

        m1 = described_class.new(symbolic_name: 'm1', access_point_source: ref_source, local_path: '/mnt/ref')
        m2 = described_class.new(symbolic_name: 'm2', access_point_source: import_source, local_path: '/mnt/imp')

        expect(m1.access_point_source).to eq(ref_source)
        expect(m1.access_point_source).to be_frozen
        expect(m2.access_point_source).to eq(import_source)
        expect(m2.access_point_source).to be_frozen
      end

      it 'raises ValidationError when access_point_source is an invalid ARN' do
        expect do
          described_class.new(symbolic_name: 'm', access_point_source: 'arn:aws:s3:::mybucket', local_path: '/mnt/a')
        end.to raise_error(Veltrunode::ValidationError, /ARN/)

        expect do
          described_class.new(
            symbolic_name: 'm',
            access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123:access-point/invalid',
            local_path: '/mnt/a'
          )
        end.to raise_error(Veltrunode::ValidationError, /ARN/)
      end
    end
  end

  describe '.validate_unique_local_paths!' do
    it 'does not raise error when all local_paths are unique' do
      mounts = [
        described_class.new(symbolic_name: 'm1', access_point_source: 'ap', local_path: '/mnt/path1'),
        described_class.new(symbolic_name: 'm2', access_point_source: 'ap', local_path: '/mnt/path2')
      ]
      expect { described_class.validate_unique_local_paths!(mounts) }.not_to raise_error
    end

    it 'raises ValidationError when duplicate local_paths exist' do
      mounts = [
        described_class.new(symbolic_name: 'm1', access_point_source: 'ap', local_path: '/mnt/shared'),
        described_class.new(symbolic_name: 'm2', access_point_source: 'ap', local_path: '/mnt/shared')
      ]
      expect { described_class.validate_unique_local_paths!(mounts) }
        .to raise_error(Veltrunode::ValidationError, /Duplicate local_path/)
    end
  end
end
