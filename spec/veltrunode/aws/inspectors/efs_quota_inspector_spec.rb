# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/efs_quota_inspector'

RSpec.describe Veltrunode::AWS::Inspectors::EfsQuotaInspector do
  let(:mock_efs_client) { double('Aws::EFS::Client') }

  let(:efs_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      local_path: '/mnt/shared',
      managed_access_point: {
        file_system_id: 'fs-0123456789abcdef0'
      }
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-quota-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      mounts: [efs_mount]
    )
  end

  let(:fs_response) do
    double(
      'FileSystemsResponse',
      file_systems: [
        double(
          'FileSystem1',
          file_system_id: 'fs-0123456789abcdef0',
          name: 'shared-fs',
          life_cycle_state: 'available',
          throughput_mode: 'bursting',
          number_of_mount_targets: 2,
          size_in_bytes: double(
            'SizeInBytes1',
            value: 1_610_612_736, # 1.5 GiB
            value_in_standard: 1_073_741_824, # 1.0 GiB
            value_in_ia: 536_870_912, # 512 MiB
            value_in_archive: 0
          )
        ),
        double(
          'FileSystem2',
          file_system_id: 'fs-fedcba98765432100',
          name: 'logs-fs',
          life_cycle_state: 'available',
          throughput_mode: 'elastic',
          number_of_mount_targets: 3,
          size_in_bytes: double(
            'SizeInBytes2',
            value: 5_368_709_120, # 5.0 GiB
            value_in_standard: 1_073_741_824, # 1.0 GiB
            value_in_ia: 2_147_483_648, # 2.0 GiB
            value_in_archive: 2_147_483_648 # 2.0 GiB
          )
        )
      ]
    )
  end

  before do
    allow(mock_efs_client).to receive(:describe_file_systems).and_return(fs_response)
  end

  describe '#inspect' do
    it 'retrieves file system sizes (Standard / IA / Archive) and regional quotas' do
      report = described_class.inspect(application, efs_client: mock_efs_client)

      expect(report.success?).to be(true)
      expect(report.region).to eq('ap-northeast-1')
      expect(report.file_systems.size).to eq(2)

      fs1 = report.file_systems.find { |f| f.file_system_id == 'fs-0123456789abcdef0' }
      expect(fs1.mount_name).to eq('shared_data')
      expect(fs1.total_bytes).to eq(1_610_612_736)
      expect(fs1.standard_bytes).to eq(1_073_741_824)
      expect(fs1.ia_bytes).to eq(536_870_912)
      expect(fs1.archive_bytes).to eq(0)
      expect(fs1.mount_targets_count).to eq(2)
      expect(fs1.mount_targets_limit).to eq(32)

      fs2 = report.file_systems.find { |f| f.file_system_id == 'fs-fedcba98765432100' }
      expect(fs2.name).to eq('logs-fs')
      expect(fs2.total_bytes).to eq(5_368_709_120)
      expect(fs2.standard_bytes).to eq(1_073_741_824)
      expect(fs2.ia_bytes).to eq(2_147_483_648)
      expect(fs2.archive_bytes).to eq(2_147_483_648)
      expect(fs2.mount_targets_count).to eq(3)

      expect(report.quotas['file_systems']).to eq(
        'used' => 2,
        'limit' => 1000,
        'usage_percent' => 0.2
      )
      expect(report.quotas['mount_targets']).to include(
        'used' => 5,
        'limit' => 1000,
        'max_per_file_system' => 32,
        'max_used_per_file_system' => 3,
        'usage_percent' => 0.5
      )
    end

    it 'filters by mount name when target_name is specified' do
      report = described_class.inspect(application, target_name: 'shared_data', efs_client: mock_efs_client)

      expect(report.success?).to be(true)
      expect(report.file_systems.size).to eq(1)
      expect(report.file_systems.first.file_system_id).to eq('fs-0123456789abcdef0')
      expect(report.quotas['file_systems']['used']).to eq(2)
    end

    it 'emits VLT-EFS-QUOTA-WARNING diagnostic when quota usage reaches 80% or higher' do
      report = described_class.inspect(
        application,
        efs_client: mock_efs_client,
        file_systems_limit: 2
      )

      expect(report.success?).to be(true)
      expect(report.warnings?).to be(true)
      warn_diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-QUOTA-WARNING' }
      expect(warn_diag).not_to be_nil
      expect(warn_diag.evidence['usage_percent']).to eq(100.0)
    end
  end
end
