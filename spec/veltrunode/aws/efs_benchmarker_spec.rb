# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'veltrunode/model'
require 'veltrunode/aws/efs_benchmarker'

RSpec.describe Veltrunode::AWS::EfsBenchmarker do
  let(:efs_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      local_path: '/mnt/shared',
      managed_access_point: {
        file_system_id: 'fs-0123456789abcdef0'
      }
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'processor',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      vpc_reference: { subnet_ids: ['subnet-123'], security_group_ids: ['sg-123'] },
      efs_mounts: ['shared_data']
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-bench-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      mounts: [efs_mount],
      functions: [function]
    )
  end

  describe '.run_io_benchmark' do
    it 'measures 4KB random I/O and 1MB sequential I/O latency/throughput and automatically cleans up test files' do
      Dir.mktmpdir('veltrunode-efs-bench-spec') do |tmpdir|
        result = described_class.run_io_benchmark(
          tmpdir,
          random_iterations: 8,
          sequential_blocks: 2
        )

        expect(result['cleaned_up']).to be(true)
        result['removed_files'].each do |file_path|
          expect(File.exist?(file_path)).to be(false)
        end
        expect(Dir.children(tmpdir)).to be_empty

        r4k = result['random_4kb']
        expect(r4k['block_size_bytes']).to eq(4096)
        expect(r4k['iterations']).to eq(8)
        expect(r4k['write_latency_ms']).to be >= 0.0
        expect(r4k['read_latency_ms']).to be >= 0.0
        expect(r4k['write_iops']).to be > 0.0
        expect(r4k['read_iops']).to be > 0.0

        s1m = result['sequential_1mb']
        expect(s1m['block_size_bytes']).to eq(1_048_576)
        expect(s1m['blocks']).to eq(2)
        expect(s1m['write_latency_ms']).to be >= 0.0
        expect(s1m['read_latency_ms']).to be >= 0.0
        expect(s1m['write_throughput_mbps']).to be > 0.0
        expect(s1m['read_throughput_mbps']).to be > 0.0
      end
    end
  end

  describe '.run with Lambda client' do
    let(:mock_lambda_client) { double('Aws::Lambda::Client') }
    let(:bench_payload_json) do
      JSON.generate(
        'random_4kb' => {
          'block_size_bytes' => 4096,
          'iterations' => 64,
          'write_latency_ms' => 1.25,
          'read_latency_ms' => 0.85,
          'write_iops' => 800.0,
          'read_iops' => 1176.47,
          'write_throughput_mbps' => 3.12,
          'read_throughput_mbps' => 4.6
        },
        'sequential_1mb' => {
          'block_size_bytes' => 1_048_576,
          'blocks' => 8,
          'write_latency_ms' => 12.5,
          'read_latency_ms' => 6.25,
          'write_throughput_mbps' => 80.0,
          'read_throughput_mbps' => 160.0
        },
        'cleaned_up' => true
      )
    end

    it 'creates a temporary benchmark function, invokes it, and deletes it in ensure' do
      fn_cfg = double(
        'FunctionConfiguration',
        role: 'arn:aws:iam::123456789012:role/processor-role',
        vpc_config: { subnet_ids: ['subnet-123'], security_group_ids: ['sg-123'] },
        file_system_configs: [{ arn: 'arn:aws:elasticfilesystem:...', local_mount_path: '/mnt/shared' }]
      )
      allow(mock_lambda_client).to receive(:get_function_configuration)
        .with(function_name: 'processor').and_return(fn_cfg)
      expect(mock_lambda_client).to receive(:create_function).with(
        hash_including(
          runtime: 'ruby3.3',
          role: 'arn:aws:iam::123456789012:role/processor-role'
        )
      )
      expect(mock_lambda_client).to receive(:invoke).and_return(
        double('InvokeResponse', payload: StringIO.new(bench_payload_json))
      )
      expect(mock_lambda_client).to receive(:delete_function)

      report = described_class.run(
        application,
        function_name: 'processor',
        lambda_client: mock_lambda_client
      )

      expect(report.success?).to be(true)
      expect(report.function_name).to eq('processor')
      expect(report.mount_path).to eq('/mnt/shared')
      expect(report.cleaned_up?).to be(true)
      expect(report.temp_function_deleted?).to be(true)
      expect(report.random_4kb['write_latency_ms']).to eq(1.25)
      expect(report.sequential_1mb['write_throughput_mbps']).to eq(80.0)
    end
  end
end
