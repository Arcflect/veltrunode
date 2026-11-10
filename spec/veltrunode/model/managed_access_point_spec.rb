# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::ManagedAccessPoint do
  let(:valid_fs_id) { 'fs-0123456789abcdef0' }
  let(:valid_attributes) do
    {
      file_system_id: valid_fs_id,
      root_directory_path: '/export/lambda',
      posix_user: { uid: 1000, gid: 1000, secondary_gids: [1001, 1002] },
      creation_info: { owner_uid: 1000, owner_gid: 1000, permissions: '0755' },
      tags: { 'Environment' => 'prod' }
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:ap) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(ap.file_system_id).to eq(valid_fs_id)
        expect(ap.root_directory_path).to eq('/export/lambda')
        expect(ap.posix_user).to eq({ 'uid' => 1000, 'gid' => 1000, 'secondary_gids' => [1001, 1002] })
        expect(ap.creation_info).to eq({ 'owner_uid' => 1000, 'owner_gid' => 1000, 'permissions' => '0755' })
        expect(ap.tags).to eq({ 'Environment' => 'prod' })
      end

      it 'defaults root_directory_path to /' do
        minimal = described_class.new(file_system_id: valid_fs_id)
        expect(minimal.root_directory_path).to eq('/')
        expect(minimal.posix_user).to be_nil
        expect(minimal.creation_info).to be_nil
        expect(minimal.tags).to eq({})
      end

      it 'normalizes creation_info permissions when given as integer' do
        ap_int_perm = described_class.new(
          file_system_id: valid_fs_id,
          creation_info: { owner_uid: 1000, owner_gid: 1000, permissions: 755 }
        )
        expect(ap_int_perm.creation_info['permissions']).to eq('0755')
      end
    end

    context 'immutability' do
      subject(:ap) { described_class.new(**valid_attributes) }

      it 'freezes the instance and its structures' do
        expect(ap).to be_frozen
        expect(ap.file_system_id).to be_frozen
        expect(ap.root_directory_path).to be_frozen
        expect(ap.posix_user).to be_frozen
        expect(ap.creation_info).to be_frozen
        expect(ap.tags).to be_frozen
      end

      it 'prevents modification of posix_user or tags' do
        expect { ap.posix_user['uid'] = 2000 }.to raise_error(FrozenError)
        expect { ap.tags['New'] = 'val' }.to raise_error(FrozenError)
      end
    end

    context 'validations' do
      it 'raises ValidationError when file_system_id is missing' do
        expect do
          described_class.new(file_system_id: nil)
        end.to raise_error(Veltrunode::ValidationError, /file_system_id is required/)

        expect do
          described_class.new(file_system_id: '')
        end.to raise_error(Veltrunode::ValidationError, /file_system_id is required/)
      end

      it 'raises ValidationError when file_system_id format is invalid' do
        expect do
          described_class.new(file_system_id: 'my-efs-filesystem')
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS file_system_id/)
      end

      it 'raises ValidationError when root_directory_path does not start with /' do
        expect do
          described_class.new(file_system_id: valid_fs_id, root_directory_path: 'relative/path')
        end.to raise_error(Veltrunode::ValidationError, %r{root_directory_path .* must start with '/'})
      end

      it 'raises ValidationError when posix_user uid or gid is negative' do
        expect do
          described_class.new(file_system_id: valid_fs_id, posix_user: { uid: -1, gid: 1000 })
        end.to raise_error(Veltrunode::ValidationError, /posix_user uid must be a non-negative integer/)

        expect do
          described_class.new(file_system_id: valid_fs_id, posix_user: { uid: 1000, gid: -5 })
        end.to raise_error(Veltrunode::ValidationError, /posix_user gid must be a non-negative integer/)
      end

      it 'raises ValidationError when creation_info owner_uid or owner_gid is missing' do
        expect do
          described_class.new(file_system_id: valid_fs_id, creation_info: { permissions: '0755' })
        end.to raise_error(Veltrunode::ValidationError, /creation_info requires owner_uid and owner_gid/)
      end
    end

    context 'lifecycle_policies' do
      it 'supports transition_to_ia and transition_to_archive via lifecycle_policies hash' do
        ap = described_class.new(
          file_system_id: valid_fs_id,
          lifecycle_policies: {
            transition_to_ia: 'AFTER_30_DAYS',
            transition_to_archive: 'AFTER_90_DAYS'
          }
        )

        expect(ap.lifecycle_policies?).to be(true)
        expect(ap.lifecycle_policies).to eq(
          'transition_to_ia' => 'AFTER_30_DAYS',
          'transition_to_archive' => 'AFTER_90_DAYS'
        )
        expect(ap.transition_to_ia).to eq('AFTER_30_DAYS')
        expect(ap.transition_to_archive).to eq('AFTER_90_DAYS')
      end

      it 'normalizes lowercase symbols, integers, and array of hashes for lifecycle_policies' do
        ap_sym = described_class.new(
          file_system_id: valid_fs_id,
          transition_to_ia: :after_14_days,
          transition_to_archive: 60
        )
        expect(ap_sym.transition_to_ia).to eq('AFTER_14_DAYS')
        expect(ap_sym.transition_to_archive).to eq('AFTER_60_DAYS')

        ap_arr = described_class.new(
          file_system_id: valid_fs_id,
          lifecycle_policies: [
            { 'TransitionToIA' => 'AFTER_7_DAYS' },
            { 'TransitionToArchive' => 'AFTER_30_DAYS' }
          ]
        )
        expect(ap_arr.transition_to_ia).to eq('AFTER_7_DAYS')
        expect(ap_arr.transition_to_archive).to eq('AFTER_30_DAYS')
      end

      it 'raises ValidationError for invalid transition_to_ia or transition_to_archive values' do
        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            lifecycle_policies: { transition_to_ia: 'AFTER_5_DAYS' }
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS lifecycle transition_to_ia/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            lifecycle_policies: { transition_to_archive: 'INVALID' }
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS lifecycle transition_to_archive/)
      end

      it 'raises ValidationError when transition_to_archive is shorter than transition_to_ia' do
        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            lifecycle_policies: {
              transition_to_ia: 'AFTER_90_DAYS',
              transition_to_archive: 'AFTER_30_DAYS'
            }
          )
        end.to raise_error(Veltrunode::ValidationError, /must not be shorter than transition_to_ia/)
      end
    end
  end
end
