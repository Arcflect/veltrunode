# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/layer_inspector'

RSpec.describe 'CLI veltrunode layer inspect NAME' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'common_gems',
      compatible_runtimes: %w[ruby3.3 ruby3.2],
      architectures: %i[x86_64 arm64],
      description: 'Shared gems for application'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'layer-inspect-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      layers: [layer]
    )
  end

  let(:mock_report) do
    Veltrunode::AWS::Inspectors::LayerInspector::Report.new(
      layer_name: 'common_gems',
      description: 'Shared gems for application',
      compatible_runtimes: %w[ruby3.3 ruby3.2],
      architectures: %w[x86_64 arm64],
      content_hash: 'abc123def45678901234567890123456',
      sha256: '9876543210fedcba9876543210fedcba',
      zip_path: 'build/artifacts/layers/common_gems.zip',
      compressed_size: 10_485_760, # 10.0 MB
      uncompressed_size: 31_457_280, # 30.0 MB
      total_entries: 1250,
      largest_entries: [
        {
          'path' => 'ruby/gems/3.3.0/gems/nokogiri-1.16.0/ports/libxml2.a',
          'size' => 15_728_640,
          'percentage' => 50.0
        },
        {
          'path' => 'ruby/gems/3.3.0/gems/grpc-1.60.0/grpc_c.so',
          'size' => 6_291_456,
          'percentage' => 20.0
        }
      ],
      published_versions: [
        {
          'version' => 2,
          'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:2',
          'created_date' => '2026-10-05T12:00:00Z',
          'description' => 'hash:abc123def45678901234567890123456'
        }
      ],
      reusable: true,
      matched_version: 2,
      matched_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:2',
      reuse_reason: "Matching content hash 'abc123def456' found in published version 2.",
      duplicate_files: [
        {
          'path' => 'vendor/bundle/ruby/3.3.0/gems/json-2.7.1/lib/json.rb',
          'size' => 12_288,
          'duplicated_in' => ['function:worker'],
          'recommendation' => "Exclude from function 'worker' bundle"
        }
      ]
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
    it '正常時にLayer情報、サイズ、再利用状態、発行履歴、最大エントリ、重複ファイルを出力すること' do
      allow(Veltrunode::AWS::Inspectors::LayerInspector).to receive(:inspect).and_return(mock_report)

      code = run_cli(%w[layer inspect common_gems])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Veltrunode Layer Inspection Report')
      expect(output).to include('Layer Name:           common_gems')
      expect(output).to include('Content Hash:         abc123def45678901234567890123456')
      expect(output).to include('Compatible Runtimes:  ruby3.3, ruby3.2')
      expect(output).to include('Architectures:        x86_64, arm64')
      expect(output).to include('Package Size:')
      expect(output).to include('Compressed:         10.0 MB (10485760 bytes)')
      expect(output).to include('Uncompressed:       30.0 MB (31457280 bytes)')
      expect(output).to include('Total Entries:      1250')
      expect(output).to include('Reuse Status:')
      expect(output).to include('Reusable:           Yes')
      expect(output).to include('Matched Version:    Version 2')
      expect(output).to include('Published Versions (AWS):')
      expect(output).to include('Version 2')
      expect(output).to include('Largest Entries:')
      expect(output).to include('50.0%')
      expect(output).to include('libxml2.a')
      expect(output).to include('Duplicate Files Across Resources:')
      expect(output).to include('json.rb')
      expect(output).to include('Also in:        function:worker')
    end
  end

  describe 'JSON出力モード (--format json)' do
    it '共通スキーマに準拠したJSONを出力し、dataに各種詳細情報が含まれること' do
      allow(Veltrunode::AWS::Inspectors::LayerInspector).to receive(:inspect).and_return(mock_report)

      code = run_cli(%w[layer inspect common_gems --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)

      expect(parsed['command']).to eq('layer inspect')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics']).to be_empty

      data = parsed['data']
      expect(data['layer_name']).to eq('common_gems')
      expect(data['content_hash']).to eq('abc123def45678901234567890123456')
      expect(data['sha256']).to eq('9876543210fedcba9876543210fedcba')
      expect(data['size']['compressed_bytes']).to eq(10_485_760)
      expect(data['size']['uncompressed_bytes']).to eq(31_457_280)
      expect(data['size']['total_entries']).to eq(1250)
      expect(data['reuse']['reusable']).to be(true)
      expect(data['reuse']['matched_version']).to eq(2)
      expect(data['published_versions'].size).to eq(1)
      expect(data['largest_entries'].size).to eq(2)
      expect(data['duplicate_files'].size).to eq(1)
    end
  end

  describe 'エラーハンドリング' do
    it 'Layer名が未指定の場合に終了コード2を返すこと' do
      code = run_cli(%w[layer inspect])

      expect(code).to eq(2)
      expect(stderr.string).to include('Layer name is required for layer inspect.')
    end

    it '存在しないLayer名が指定された場合に終了コード2を返すこと' do
      code = run_cli(%w[layer inspect unknown_layer])

      expect(code).to eq(2)
      expect(stderr.string).to include("Layer 'unknown_layer' not found in application 'layer-inspect-app'.")
    end
  end
end
