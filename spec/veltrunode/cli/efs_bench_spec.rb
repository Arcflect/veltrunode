# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/efs_benchmarker'

RSpec.describe 'CLI veltrunode efs bench <function_name>' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:efs_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      local_path: '/mnt/shared',
      managed_access_point: {
        file_system_id: 'fs-0123456789abcdef0'
      }
    )
  end

  let(:mounted_fn) do
    Veltrunode::Model::Function.new(
      logical_name: 'processor',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      vpc_reference: { subnet_ids: ['subnet-123'], security_group_ids: ['sg-123'] },
      efs_mounts: ['shared_data']
    )
  end

  let(:unmounted_fn) do
    Veltrunode::Model::Function.new(
      logical_name: 'plain_fn',
      handler: 'plain.handler',
      runtime: 'ruby3.3'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-bench-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      mounts: [efs_mount],
      functions: [mounted_fn, unmounted_fn]
    )
  end

  let(:mock_report) do
    Veltrunode::AWS::EfsBenchmarker::Report.new(
      function_name: 'processor',
      mount_path: '/mnt/shared',
      region: 'ap-northeast-1',
      random_4kb: {
        'block_size_bytes' => 4096,
        'iterations' => 64,
        'write_latency_ms' => 1.25,
        'read_latency_ms' => 0.85,
        'write_iops' => 800.0,
        'read_iops' => 1176.0,
        'write_throughput_mbps' => 3.12,
        'read_throughput_mbps' => 4.60
      },
      sequential_1mb: {
        'block_size_bytes' => 1_048_576,
        'blocks' => 8,
        'write_latency_ms' => 12.5,
        'read_latency_ms' => 6.25,
        'write_throughput_mbps' => 80.0,
        'read_throughput_mbps' => 160.0
      },
      cleaned_up: true,
      temp_function_name: 'processor-efs-bench-a1b2c3d4',
      temp_function_deleted: true
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
    it '4KB ランダム I/O および 1MB シーケンシャル I/O のベンチマーク結果とクリーンアップ完了を表示すること' do
      allow(Veltrunode::AWS::EfsBenchmarker).to receive(:run).and_return(mock_report)

      code = run_cli(%w[efs bench processor])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Veltrunode EFS I/O Benchmark Report')
      expect(output).to include('Function:            processor')
      expect(output).to include('Mount Path:          /mnt/shared')
      expect(output).to include('Temp File Cleanup:   COMPLETED')
      expect(output).to include('4KB Random I/O')
      expect(output).to include('1.250 ms')
      expect(output).to include('0.850 ms')
      expect(output).to include('1MB Sequential I/O')
      expect(output).to include('80.00 MB/s')
      expect(output).to include('160.00 MB/s')
    end

    it '関数名が指定されていない場合は終了コード 2 を返すこと' do
      code = run_cli(%w[efs bench])

      expect(code).to eq(2)
      expect(stderr.string).to include('Function name is required for efs bench')
    end

    it '対象関数に EFS マウントが設定されていない場合は終了コード 3 を返すこと' do
      code = run_cli(%w[efs bench plain_fn])

      expect(code).to eq(3)
      expect(stderr.string).to include("Function 'plain_fn' does not have any EFS mounts configured")
    end
  end

  describe 'JSON 出力モード (--format json)' do
    it '共通スキーマに準拠した JSON でベンチマーク結果を出力すること' do
      allow(Veltrunode::AWS::EfsBenchmarker).to receive(:run).and_return(mock_report)

      code = run_cli(%w[efs bench processor --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)
      expect(parsed['command']).to eq('efs bench')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['function_name']).to eq('processor')
      expect(parsed['data']['mount_path']).to eq('/mnt/shared')
      expect(parsed['data']['cleaned_up']).to be(true)
      expect(parsed['data']['random_4kb']['block_size_bytes']).to eq(4096)
      expect(parsed['data']['random_4kb']['write_latency_ms']).to eq(1.25)
      expect(parsed['data']['sequential_1mb']['block_size_bytes']).to eq(1_048_576)
      expect(parsed['data']['sequential_1mb']['write_throughput_mbps']).to eq(80.0)
    end
  end
end
