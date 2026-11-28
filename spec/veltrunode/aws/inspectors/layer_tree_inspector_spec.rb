# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/aws/inspectors/layer_tree_inspector'
require 'veltrunode/model'

RSpec.describe Veltrunode::AWS::Inspectors::LayerTreeInspector do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-layer-tree-spec-') }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  before do
    lockfile_content = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          faraday (2.9.0)
            faraday-net_http (~> 3.0)
          faraday-net_http (3.1.0)
          nokogiri (1.16.0)
            racc (~> 1.4)
          oj (3.16.3)
          racc (1.7.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        faraday
        nokogiri
        oj

      BUNDLED WITH
         2.5.6
    LOCK
    File.write(File.join(tmpdir, 'Gemfile.lock'), lockfile_content)

    # vendor/bundle 配下にダミーの Gem ファイルと gemspec を配置してサイズ・ライセンス解決を検証
    gems_base = File.join(tmpdir, 'vendor', 'bundle', 'ruby', '3.3.0', 'gems')
    specs_base = File.join(tmpdir, 'vendor', 'bundle', 'ruby', '3.3.0', 'specifications')
    FileUtils.mkdir_p(gems_base)
    FileUtils.mkdir_p(specs_base)

    {
      'nokogiri-1.16.0' => { size: 2048, license: 'MIT' },
      'racc-1.7.3' => { size: 1024, license: 'BSD-2-Clause' },
      'oj-3.16.3' => { size: 4096, license: 'MIT' },
      'faraday-2.9.0' => { size: 1536, license: 'MIT' },
      'faraday-net_http-3.1.0' => { size: 512, license: 'MIT' }
    }.each do |full_name, meta|
      gem_dir = File.join(gems_base, full_name)
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, 'lib.rb'), 'x' * meta[:size])
      File.write(
        File.join(specs_base, "#{full_name}.gemspec"),
        <<~SPEC
          Gem::Specification.new do |s|
            s.license = "#{meta[:license]}"
          end
        SPEC
      )
    end
  end

  let(:common_layer) do
    Veltrunode::Model::Layer.new(
      name: 'common_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64],
      build_environment: { 'include_gems' => %w[nokogiri oj] }
    )
  end

  let(:http_layer) do
    Veltrunode::Model::Layer.new(
      name: 'http_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64],
      build_environment: { 'include_gems' => %w[faraday oj] }
    )
  end

  let(:api_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_handler',
      handler: 'app.call',
      runtime: 'ruby3.3',
      architecture: :x86_64,
      layers: %w[common_gems http_gems]
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'tree-demo-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      functions: [api_function],
      layers: [common_layer, http_layer]
    )
  end

  describe '.inspect' do
    it '関数・Layer・Gem（バージョン・サイズ・ライセンス・依存階層）のツリーと競合を検出すること' do
      report = described_class.inspect(application, source_dir: tmpdir)

      expect(report.application_name).to eq('tree-demo-app')
      expect(report.functions.size).to eq(1)
      expect(report.layers.size).to eq(2)
      expect(report.conflicts?).to be(true)

      # oj が common_gems と http_gems の両方に存在するため重複競合として検出される
      oj_conflict = report.conflicts.find { |c| c['gem_name'] == 'oj' }
      expect(oj_conflict).not_to be_nil
      expect(oj_conflict['conflict_type']).to eq('duplicate')
      expect(oj_conflict['affected_functions']).to include('api_handler')
      expect(report.diagnostics.map(&:code)).to include('VLT-LAYER-CONFLICT-001')

      # common_gems 内の nokogiri -> racc の親子依存ツリーを確認
      common_node = report.layers.find { |l| l.layer_name == 'common_gems' }
      nokogiri_node = common_node.root_gems.find { |g| g.name == 'nokogiri' }
      expect(nokogiri_node.version).to eq('1.16.0')
      expect(nokogiri_node.size_bytes).to eq(2048)
      expect(nokogiri_node.formatted_size).to eq('2.0 KB')
      expect(nokogiri_node.license).to eq('MIT')
      expect(nokogiri_node.dependencies.map(&:name)).to eq(['racc'])
      expect(nokogiri_node.dependencies.first.license).to eq('BSD-2-Clause')

      # アスキーアートツリーの描画検証
      tree_text = report.render_ascii_tree
      expect(tree_text).to include('Function: api_handler (ruby3.3, x86_64)')
      expect(tree_text).to include('├── Layer: common_gems')
      expect(tree_text).to include('└── Layer: http_gems')
      expect(tree_text).to include('nokogiri (1.16.0) [2.0 KB, license: MIT]')
      expect(tree_text).to include('└── racc (1.7.3) [1.0 KB, license: BSD-2-Clause]')
      expect(tree_text).to include(
        'oj (3.16.3) [4.0 KB, license: MIT] ⚠️ [CONFLICT: duplicate with http_gems (3.16.3)]'
      )
      expect(tree_text).to include('Conflicts Detected (1):')
    end

    it '別バージョンの同名 Gem が複数 Layer に存在する場合は version_mismatch としてハイライトすること' do
      legacy_layer = Veltrunode::Model::Layer.new(
        name: 'legacy_gems',
        compatible_runtimes: ['ruby3.3'],
        build_environment: {
          'gems' => [
            { 'name' => 'oj', 'version' => '3.14.0', 'size_bytes' => 3072, 'license' => 'MIT' }
          ]
        }
      )
      app = Veltrunode::Model::Application.new(
        name: 'mismatch-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        functions: [
          Veltrunode::Model::Function.new(
            logical_name: 'worker',
            handler: 'worker.call',
            runtime: 'ruby3.3',
            layers: %w[common_gems legacy_gems]
          )
        ],
        layers: [common_layer, legacy_layer]
      )

      report = described_class.inspect(app, source_dir: tmpdir)
      conflict = report.conflicts.find { |c| c['gem_name'] == 'oj' }
      expect(conflict['conflict_type']).to eq('version_mismatch')

      tree_text = report.render_ascii_tree
      expect(tree_text).to include('CONFLICT: version mismatch with legacy_gems (3.14.0)')
      expect(tree_text).to include('[VERSION MISMATCH] oj: common_gems (3.16.3), legacy_gems (3.14.0)')
    end

    it '存在しない target_name が指定された場合は ArgumentError を送出すること' do
      expect do
        described_class.inspect(application, target_name: 'non_existent', source_dir: tmpdir)
      end.to raise_error(ArgumentError, /Function or Layer 'non_existent' not found/)
    end
  end
end
