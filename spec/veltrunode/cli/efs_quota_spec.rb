# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/efs_quota_inspector'

RSpec.describe 'CLI veltrunode efs quota' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-quota-app',
      region: 'ap-northeast-1',
      stage: 'dev'
    )
  end

  let(:fs_usage) do
    Veltrunode::AWS::Inspectors::EfsQuotaInspector::FileSystemUsage.new(
      file_system_id: 'fs-0123456789abcdef0',
      name: 'shared-fs',
      mount_name: 'shared_data',
      life_cycle_state: 'available',
      throughput_mode: 'bursting',
      total_bytes: 1_610_612_736, # 1.50 GiB
      standard_bytes: 1_073_741_824, # 1.00 GiB
      ia_bytes: 536_870_912, # 512.00 MiB
      archive_bytes: 0,
      mount_targets_count: 2,
      mount_targets_limit: 32
    )
  end

  let(:mock_report) do
    Veltrunode::AWS::Inspectors::EfsQuotaInspector::Report.new(
      region: 'ap-northeast-1',
      file_systems: [fs_usage],
      quotas: {
        'file_systems' => {
          'used' => 1,
          'limit' => 1000,
          'usage_percent' => 0.1
        },
        'mount_targets' => {
          'used' => 2,
          'limit' => 1000,
          'max_per_file_system' => 32,
          'max_used_per_file_system' => 2,
          'max_per_file_system_usage_percent' => 6.25,
          'usage_percent' => 0.2
        }
      },
      diagnostics: []
    )
  end

  before do
    allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
    allow($stdout).to receive(:print) { |val| stdout.print(val) }
    allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    allow(Veltrunode::SettingsLoader).to receive(:load).and_return(application)
  end

  def run_cli(args)
    stdout.string.clear
    stderr.string.clear
    Veltrunode::CLI::Router.run(args)
  end

  describe 'テキスト出力モード（デフォルト）' do
    it 'ファイルシステムのサイズ内訳（Standard / IA / Archive）とリージョン内クォータを表形式で出力すること' do
      allow(Veltrunode::AWS::Inspectors::EfsQuotaInspector).to receive(:inspect).and_return(mock_report)

      code = run_cli(%w[efs quota])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Veltrunode EFS Storage & Quota Report (Region: ap-northeast-1)')
      expect(output).to include('File Systems Storage Breakdown:')
      expect(output).to include('fs-0123456789abcdef0')
      expect(output).to include('shared_data')
      expect(output).to include('1.50 GiB')
      expect(output).to include('1.00 GiB')
      expect(output).to include('512.00 MiB')
      expect(output).to include('256.00 TiB')
      expect(output).to include('2 / 32')
      expect(output).to include('Regional EFS Quotas (ap-northeast-1):')
      expect(output).to include('File Systems')
      expect(output).to include('1,000')
      expect(output).to include('Mount Targets (Total)')
      expect(output).to include('Mount Targets (Max per File System)')
    end
  end

  describe 'JSON 出力モード (--format json)' do
    it '共通スキーマに準拠した JSON（ファイルシステムサイズ内訳・クォータ情報）を出力すること' do
      allow(Veltrunode::AWS::Inspectors::EfsQuotaInspector).to receive(:inspect).and_return(mock_report)

      code = run_cli(%w[efs quota --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)
      expect(parsed['command']).to eq('efs quota')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics']).to be_empty
      expect(parsed['data']['region']).to eq('ap-northeast-1')

      fs_data = parsed['data']['file_systems'].first
      expect(fs_data['file_system_id']).to eq('fs-0123456789abcdef0')
      expect(fs_data['size_in_bytes']['total']).to eq(1_610_612_736)
      expect(fs_data['size_in_bytes']['standard']).to eq(1_073_741_824)
      expect(fs_data['size_in_bytes']['ia']).to eq(536_870_912)
      expect(fs_data['mount_targets']).to eq('used' => 2, 'limit' => 32)

      quotas_data = parsed['data']['quotas']
      expect(quotas_data['file_systems']).to eq('used' => 1, 'limit' => 1000, 'usage_percent' => 0.1)
      expect(quotas_data['mount_targets']['used']).to eq(2)
      expect(quotas_data['mount_targets']['limit']).to eq(1000)
    end
  end
end
