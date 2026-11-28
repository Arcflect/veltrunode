# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/layer_tree_inspector'

RSpec.describe 'CLI veltrunode layer tree [NAME]' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:common_layer) do
    Veltrunode::Model::Layer.new(
      name: 'common_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64],
      build_environment: {
        'gems' => [
          {
            'name' => 'nokogiri',
            'version' => '1.16.0',
            'size_bytes' => 1_258_291,
            'license' => 'MIT',
            'dependencies' => ['racc']
          },
          {
            'name' => 'racc',
            'version' => '1.7.3',
            'size_bytes' => 327_680,
            'license' => 'BSD-2-Clause',
            'dependencies' => []
          },
          {
            'name' => 'oj',
            'version' => '3.16.3',
            'size_bytes' => 317_440,
            'license' => 'MIT',
            'dependencies' => []
          }
        ]
      }
    )
  end

  let(:api_layer) do
    Veltrunode::Model::Layer.new(
      name: 'api_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64],
      build_environment: {
        'gems' => [
          {
            'name' => 'faraday',
            'version' => '2.9.0',
            'size_bytes' => 204_800,
            'license' => 'MIT',
            'dependencies' => []
          },
          {
            'name' => 'oj',
            'version' => '3.16.3',
            'size_bytes' => 317_440,
            'license' => 'MIT',
            'dependencies' => []
          }
        ]
      }
    )
  end

  let(:api_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api',
      handler: 'api.handler',
      runtime: 'ruby3.3',
      architecture: :x86_64,
      layers: %w[common_gems api_gems]
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'layer-tree-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      functions: [api_function],
      layers: [common_layer, api_layer]
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
    it 'veltrunode layer tree でアスキーアートツリー、Gemのバージョン・サイズ・ライセンス、および競合ハイライトを表示すること' do
      code = run_cli(%w[layer tree])

      expect(code).to eq(0)
      output = stdout.string

      expect(output).to include('Veltrunode Layer Dependency Tree (layer-tree-app)')
      expect(output).to include('└── Function: api (ruby3.3, x86_64)')
      expect(output).to include('├── Layer: common_gems (runtimes: ruby3.3, total: 1.8 MB)')
      expect(output).to include('└── Layer: api_gems (runtimes: ruby3.3, total: 510.0 KB)')
      expect(output).to include('├── nokogiri (1.16.0) [1.2 MB, license: MIT]')
      expect(output).to include('│   └── racc (1.7.3) [320.0 KB, license: BSD-2-Clause]')
      expect(output).to include(
        '└── oj (3.16.3) [310.0 KB, license: MIT] ⚠️ [CONFLICT: duplicate with api_gems (3.16.3)]'
      )
      expect(output).to include('Conflicts Detected (1):')
      expect(output).to include('⚠️ [DUPLICATE] oj: common_gems (3.16.3), api_gems (3.16.3) [functions: api]')
    end

    it '特定の Layer 名や Function 名を引数に指定してフィルタ表示できること' do
      code = run_cli(%w[layer tree common_gems])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Layer: common_gems')
      expect(output).to include('nokogiri (1.16.0)')
    end
  end

  describe 'JSON出力モード (--format json)' do
    it '共通スキーマに準拠した JSON と競合診断情報 VLT-LAYER-CONFLICT-001 を出力すること' do
      code = run_cli(%w[layer tree --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)

      expect(parsed['command']).to eq('layer tree')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics'].first['code']).to eq('VLT-LAYER-CONFLICT-001')

      data = parsed['data']
      expect(data['application_name']).to eq('layer-tree-app')
      expect(data['functions'].first['function_name']).to eq('api')
      expect(data['layers'].size).to eq(2)
      expect(data['conflicts'].first['gem_name']).to eq('oj')
    end
  end

  describe 'エラーハンドリング' do
    it '存在しない関数またはLayer名が指定された場合に終了コード2を返すこと' do
      code = run_cli(%w[layer tree unknown_target])

      expect(code).to eq(2)
      expect(stderr.string).to include("Function or Layer 'unknown_target' not found in application 'layer-tree-app'.")
    end
  end
end
