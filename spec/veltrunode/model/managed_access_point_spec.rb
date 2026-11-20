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

    context 'throughput_mode and provisioned_throughput_in_mibps' do
      it 'supports bursting and elastic throughput_mode' do
        ap_elastic = described_class.new(file_system_id: valid_fs_id, throughput_mode: :elastic)
        expect(ap_elastic.throughput_mode).to eq('elastic')
        expect(ap_elastic.provisioned_throughput_in_mibps).to be_nil
        expect(ap_elastic.throughput_configuration?).to be(true)

        ap_bursting = described_class.new(file_system_id: valid_fs_id, throughput_mode: 'bursting')
        expect(ap_bursting.throughput_mode).to eq('bursting')
      end

      it 'supports provisioned throughput_mode with numeric provisioned_throughput_in_mibps' do
        ap_prov = described_class.new(
          file_system_id: valid_fs_id,
          throughput_mode: :provisioned,
          provisioned_throughput_in_mibps: 100
        )
        expect(ap_prov.throughput_mode).to eq('provisioned')
        expect(ap_prov.provisioned_throughput_in_mibps).to eq(100)

        ap_float = described_class.new(
          file_system_id: valid_fs_id,
          throughput_mode: :provisioned,
          provisioned_throughput_in_mibps: 256.5
        )
        expect(ap_float.provisioned_throughput_in_mibps).to eq(256.5)
      end

      it 'raises ValidationError when throughput_mode is invalid' do
        expect do
          described_class.new(file_system_id: valid_fs_id, throughput_mode: :invalid_mode)
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS throughput_mode/)
      end

      it 'raises ValidationError when throughput_mode is provisioned without provisioned_throughput_in_mibps' do
        expect do
          described_class.new(file_system_id: valid_fs_id, throughput_mode: :provisioned)
        end.to raise_error(Veltrunode::ValidationError, /requires provisioned_throughput_in_mibps/)
      end

      it 'raises ValidationError when provisioned_throughput_in_mibps is non-positive or non-numeric' do
        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            throughput_mode: :provisioned,
            provisioned_throughput_in_mibps: 0
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS provisioned_throughput_in_mibps/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            throughput_mode: :provisioned,
            provisioned_throughput_in_mibps: -10
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS provisioned_throughput_in_mibps/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            throughput_mode: :provisioned,
            provisioned_throughput_in_mibps: 'not_a_number'
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS provisioned_throughput_in_mibps/)
      end

      it 'raises ValidationError when provisioned_throughput_in_mibps is set with elastic or bursting mode' do
        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            throughput_mode: :elastic,
            provisioned_throughput_in_mibps: 100
          )
        end.to raise_error(Veltrunode::ValidationError, /can only be specified when throughput_mode is 'provisioned'/)
      end
    end

    context 'backup configuration' do
      it 'supports backup: true with default schedule and retention_days' do
        ap = described_class.new(file_system_id: valid_fs_id, backup: true)
        expect(ap.backup?).to be(true)
        expect(ap.backup_schedule).to eq('cron(0 12 * * ? *)')
        expect(ap.backup_retention_days).to eq(30)
        expect(ap.backup).to eq('schedule' => 'cron(0 12 * * ? *)', 'retention_days' => 30)
      end

      it 'supports custom backup hash with schedule and retention_days' do
        ap = described_class.new(
          file_system_id: valid_fs_id,
          backup: { schedule: 'cron(0 3 * * ? *)', retention_days: 90, cold_storage_after_days: 14 }
        )
        expect(ap.backup?).to be(true)
        expect(ap.backup_schedule).to eq('cron(0 3 * * ? *)')
        expect(ap.backup_retention_days).to eq(90)
        expect(ap.backup_cold_storage_after_days).to eq(14)
      end

      it 'raises ValidationError when schedule or retention_days is invalid' do
        expect do
          described_class.new(file_system_id: valid_fs_id, backup: { schedule: 'invalid', retention_days: 30 })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS backup schedule/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            backup: { schedule: 'cron(0 12 * * ? *)', retention_days: 0 }
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS backup retention_days/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            backup: { schedule: 'cron(0 12 * * ? *)', retention_days: 30, cold_storage_after_days: 30 }
          )
        end.to raise_error(Veltrunode::ValidationError, /cold_storage_after_days .* must be less than retention_days/)
      end
    end

    context 'alarms configuration (BurstCreditBalance and PercentIOLimit)' do
      it 'supports alarms: true with default thresholds for BurstCreditBalance and PercentIOLimit' do
        ap = described_class.new(file_system_id: valid_fs_id, alarms: true)
        expect(ap.alarms?).to be(true)
        expect(ap.burst_credit_balance_threshold).to eq(1_073_741_824)
        expect(ap.percent_io_limit_threshold).to eq(80)
        expect(ap.alarms['burst_credit_balance']['metric_name']).to eq('BurstCreditBalance')
        expect(ap.alarms['burst_credit_balance']['comparison_operator']).to eq('LessThanOrEqualToThreshold')
        expect(ap.alarms['burst_credit_balance']['statistic']).to eq('Minimum')
        expect(ap.alarms['percent_io_limit']['metric_name']).to eq('PercentIOLimit')
        expect(ap.alarms['percent_io_limit']['comparison_operator']).to eq('GreaterThanOrEqualToThreshold')
        expect(ap.alarms['percent_io_limit']['statistic']).to eq('Average')
      end

      it 'supports custom BurstCreditBalance and PercentIOLimit thresholds and byte unit strings' do
        ap = described_class.new(
          file_system_id: valid_fs_id,
          alarms: {
            burst_credit_balance: '10GB',
            percent_io_limit: 85,
            topic: :alert_topic
          }
        )
        expect(ap.alarms?).to be(true)
        expect(ap.burst_credit_balance_threshold).to eq(10_000_000_000)
        expect(ap.percent_io_limit_threshold).to eq(85)
        expect(ap.alarm_topic).to eq(:alert_topic)
      end

      it 'raises ValidationError when BurstCreditBalance or PercentIOLimit threshold is invalid' do
        expect do
          described_class.new(file_system_id: valid_fs_id, alarms: { burst_credit_balance: 0 })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS alarm burst_credit_balance threshold/)

        expect do
          described_class.new(file_system_id: valid_fs_id, alarms: { burst_credit_balance: -500 })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS alarm burst_credit_balance threshold/)

        expect do
          described_class.new(file_system_id: valid_fs_id, alarms: { percent_io_limit: 105 })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS alarm percent_io_limit threshold/)

        expect do
          described_class.new(file_system_id: valid_fs_id, alarms: { percent_io_limit: 0 })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS alarm percent_io_limit threshold/)
      end
    end

    context 'encryption and kms_key_id configuration' do
      let(:valid_kms_arn) { 'arn:aws:kms:ap-northeast-1:123456789012:key/12345678-1234-1234-1234-123456789012' }

      it 'supports encrypted: true and kms_key_id with KMS key ARN' do
        ap = described_class.new(
          file_system_id: valid_fs_id,
          encrypted: true,
          kms_key_id: valid_kms_arn
        )
        expect(ap.encrypted).to be(true)
        expect(ap.encrypted?).to be(true)
        expect(ap.kms_key?).to be(true)
        expect(ap.kms_key_id).to eq(valid_kms_arn)
        expect(ap.encryption_configuration?).to be(true)
        expect(ap.file_system_configuration?).to be(true)
      end

      it 'automatically enables encrypted when kms_key_id is specified' do
        ap = described_class.new(file_system_id: valid_fs_id, kms_key_id: valid_kms_arn)
        expect(ap.encrypted).to be(true)
        expect(ap.encrypted?).to be(true)
        expect(ap.kms_key_id).to eq(valid_kms_arn)
      end

      it 'raises ValidationError when kms_key_id is invalid or encrypted is false with kms_key_id' do
        expect do
          described_class.new(file_system_id: valid_fs_id, encrypted: false, kms_key_id: valid_kms_arn)
        end.to raise_error(Veltrunode::ValidationError, /cannot be specified when encrypted is false/)

        expect do
          described_class.new(file_system_id: valid_fs_id, kms_key_id: 'arn:aws:s3:::invalid-arn')
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS kms_key_id ARN/)
      end
    end

    context 'replication configuration (Cross-Region DR)' do
      let(:dest_kms_arn) { 'arn:aws:kms:us-west-2:123456789012:key/12345678-1234-1234-1234-123456789012' }

      it 'supports replication with destination_region and destination kms_key_id' do
        ap = described_class.new(
          file_system_id: valid_fs_id,
          replication: {
            destination_region: 'us-west-2',
            kms_key_id: dest_kms_arn
          }
        )
        expect(ap.replication?).to be(true)
        expect(ap.replication_destination_region).to eq('us-west-2')
        expect(ap.replication_kms_key_id).to eq(dest_kms_arn)
      end

      it 'raises ValidationError when destination_region is invalid, KMS region mismatches, or encrypted is false' do
        expect do
          described_class.new(file_system_id: valid_fs_id, replication: { destination_region: 'invalid_region' })
        end.to raise_error(Veltrunode::ValidationError, /Invalid EFS replication destination_region/)

        wrong_region_kms = 'arn:aws:kms:ap-northeast-1:123456789012:key/12345678-1234-1234-1234-123456789012'
        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            replication: { destination_region: 'us-west-2', kms_key_id: wrong_region_kms }
          )
        end.to raise_error(Veltrunode::ValidationError, /KMS key ARN region \('ap-northeast-1'\) does not match/)

        expect do
          described_class.new(
            file_system_id: valid_fs_id,
            encrypted: false,
            replication: { destination_region: 'us-west-2' }
          )
        end.to raise_error(Veltrunode::ValidationError, /encrypted cannot be false when replication is configured/)
      end
    end
  end
end
