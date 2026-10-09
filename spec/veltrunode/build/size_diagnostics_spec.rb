# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'
require 'veltrunode/build/size_diagnostics'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::Build::SizeDiagnostics do
  let(:tmp_dir) { Dir.mktmpdir('size_diag_spec_') }
  let(:app) do
    Veltrunode::Model::Application.new(
      name: 'test-app',
      region: 'ap-northeast-1'
    )
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  def create_test_zip(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    Zip::File.open(path, Zip::File::CREATE) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { |f| f.write(content) }
      end
    end
  end

  describe '.analyze' do
    context 'with normal sized function and layer' do
      let(:fn_zip) { File.join(tmp_dir, 'build', 'artifacts', 'functions', 'worker.zip') }
      let(:layer_zip) { File.join(tmp_dir, 'build', 'artifacts', 'layers', 'base.zip') }

      before do
        create_test_zip(
          fn_zip,
          {
            'app.rb' => 'puts "hello world"',
            'helper.rb' => 'def help; end'
          }
        )
        create_test_zip(
          layer_zip,
          {
            'ruby/gems/3.3.0/gems/rake-13.0.6/lib/rake.rb' => 'module Rake; end' * 100,
            'ruby/gems/3.3.0/gems/json-2.6.3/lib/json.rb' => 'module JSON; end' * 200
          }
        )
      end

      it 'analyzes compressed and uncompressed sizes and percentages' do
        fn_res = double('PackageResult', function_name: 'worker', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        expect(report.artifacts.size).to eq(2)

        fn_art = report.functions.first
        expect(fn_art.name).to eq('worker')
        expect(fn_art.compressed_size).to be > 0
        expect(fn_art.uncompressed_size).to be > 0
        expect(fn_art.compressed_percentage).to be >= 0.0
        expect(fn_art.uncompressed_percentage).to be >= 0.0
        expect(fn_art.compressed_exceeded?).to be false
        expect(fn_art.uncompressed_exceeded?).to be false

        layer_art = report.layers.first
        expect(layer_art.name).to eq('base')
        expect(layer_art.compressed_size).to be > 0
        expect(layer_art.uncompressed_size).to be > 0
        expect(layer_art.compressed_percentage).to be >= 0.0
        expect(layer_art.uncompressed_percentage).to be >= 0.0
      end

      it 'provides top largest entries per artifact and overall' do
        fn_res = double('PackageResult', function_name: 'worker', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        layer_art = report.layers.first
        expect(layer_art.largest_entries.size).to eq(2)
        expect(layer_art.largest_entries.first['path']).to include('json.rb')

        expect(report.largest_entries).not_to be_empty
        expect(report.largest_entries.first['path']).to include('json.rb')
      end

      it 'recommends placement based on size and role' do
        fn_res = double('PackageResult', function_name: 'worker', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        fn_rec = report.placement_recommendations.find { |r| r['resource'] == 'worker' }
        expect(fn_rec['target']).to eq('Function')

        layer_rec = report.placement_recommendations.find { |r| r['resource'] == 'base' }
        expect(layer_rec['target']).to eq('Layer')
      end

      it 'produces structured JSON output via to_h' do
        fn_res = double('PackageResult', function_name: 'worker', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        h = report.to_h
        expect(h).to have_key('artifacts')
        expect(h).to have_key('top_largest_entries')
        expect(h).to have_key('duplicates')
        expect(h).to have_key('placement_recommendations')
        expect(h).to have_key('diagnostics')
      end

      it 'produces human readable text via to_text' do
        fn_res = double('PackageResult', function_name: 'worker', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        text = report.to_text
        expect(text).to include('Package Size Diagnostics:')
        expect(text).to include('worker')
        expect(text).to include('base')
        expect(text).to include('50.0 MB')
        expect(text).to include('250.0 MB')
      end
    end

    context 'with duplicates between layers' do
      let(:layer1_zip) { File.join(tmp_dir, 'build', 'artifacts', 'layers', 'base.zip') }
      let(:layer2_zip) { File.join(tmp_dir, 'build', 'artifacts', 'layers', 'deps.zip') }

      before do
        create_test_zip(
          layer1_zip,
          {
            'ruby/gems/3.3.0/gems/shared-1.0/lib/shared.rb' => 'module Shared; end',
            'ruby/gems/3.3.0/gems/unique1/lib/u1.rb' => 'module U1; end'
          }
        )
        create_test_zip(
          layer2_zip,
          {
            'ruby/gems/3.3.0/gems/shared-1.0/lib/shared.rb' => 'module Shared; end',
            'ruby/gems/3.3.0/gems/unique2/lib/u2.rb' => 'module U2; end'
          }
        )
      end

      it 'detects duplicate files between layers and recommends consolidation' do
        layer1_res = double('LayerPackageResult', layer_name: 'base', zip_path: layer1_zip)
        layer2_res = double('LayerPackageResult', layer_name: 'deps', zip_path: layer2_zip)

        report = described_class.analyze(
          app,
          layer_results: [layer1_res, layer2_res],
          source_dir: tmp_dir
        )

        expect(report.layer_duplicates.size).to eq(1)
        dup = report.layer_duplicates.first
        expect(dup['path']).to include('shared.rb')
        expect(dup['layers']).to contain_exactly('base', 'deps')
        expect(dup['recommendation']).to include('Consolidate into a single shared layer')

        text = report.to_text
        expect(text).to include('Duplicate Files:')
        expect(text).to include('Between Layers:')
      end
    end

    context 'with duplicates between function and layer' do
      let(:fn_zip) { File.join(tmp_dir, 'build', 'artifacts', 'functions', 'api.zip') }
      let(:layer_zip) { File.join(tmp_dir, 'build', 'artifacts', 'layers', 'common.zip') }

      before do
        create_test_zip(
          fn_zip,
          {
            'vendor/bundle/ruby/3.3.0/gems/json-2.6.3/lib/json.rb' => 'module JSON; end',
            'app.rb' => 'require "json"'
          }
        )
        create_test_zip(
          layer_zip,
          {
            'ruby/gems/3.3.0/gems/json-2.6.3/lib/json.rb' => 'module JSON; end'
          }
        )
      end

      it 'detects duplicate files between function and layer and recommends exclusion' do
        fn_res = double('PackageResult', function_name: 'api', zip_path: fn_zip)
        layer_res = double('LayerPackageResult', layer_name: 'common', zip_path: layer_zip)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          layer_results: [layer_res],
          source_dir: tmp_dir
        )

        expect(report.function_layer_duplicates.size).to eq(1)
        dup = report.function_layer_duplicates.first
        expect(dup['function']).to eq('api')
        expect(dup['layer']).to eq('common')
        expect(dup['path']).to include('json.rb')
        expect(dup['recommendation']).to include("Exclude 'vendor/bundle/ruby/3.3.0/gems/json-2.6.3/lib/json.rb'")

        text = report.to_text
        expect(text).to include('Between Functions and Layers:')
        expect(text).to include('common')
      end
    end

    context 'when size limits are exceeded' do
      let(:heavy_zip) { File.join(tmp_dir, 'build', 'artifacts', 'functions', 'heavy.zip') }

      before do
        # 実際に250MB書くとテストが重くなるため、ArtifactReportのテストで直接制限超過を検証、
        # またはモック/スタブでサイズを調整する
        create_test_zip(heavy_zip, { 'data.bin' => 'x' * 1024 })
      end

      it 'generates warning diagnostics and EFS recommendation when limits are exceeded' do
        fn_res = double('PackageResult', function_name: 'heavy', zip_path: heavy_zip)

        # File.size と uncompressed_size をスタブ
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(heavy_zip).and_return(55 * 1024 * 1024) # 55MB (> 50MB)

        # Zip::Entry の size をスタブして 260MB (> 250MB)
        allow_any_instance_of(Zip::Entry).to receive(:size).and_return(260 * 1024 * 1024)

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          source_dir: tmp_dir
        )

        art = report.functions.first
        expect(art.compressed_exceeded?).to be true
        expect(art.uncompressed_exceeded?).to be true
        expect(art.compressed_percentage).to be > 100.0
        expect(art.uncompressed_percentage).to be > 100.0

        expect(report.exceeded?).to be true

        # 警告診断が生成されていること
        expect(report.diagnostics.size).to be >= 1
        warnings = report.diagnostics.select { |d| d.code == 'VLT-BUILD-SIZE-LIMIT' }
        expect(warnings).not_to be_empty
        expect(warnings.first.severity).to eq(:warning)
        expect(warnings.first.suggested_action).to include('EFS')

        # EFS配置推奨が出ていること
        efs_recs = report.placement_recommendations.select { |r| r['target'] == 'EFS' }
        expect(efs_recs).not_to be_empty
        expect(efs_recs.first['recommendation']).to include('exceeds Lambda limit')

        # to_text に警告が表示されること
        text = report.to_text
        expect(text).to include('[! COMPRESSED LIMIT EXCEEDED, UNCOMPRESSED LIMIT EXCEEDED]')
        expect(text).to include('Warnings:')
        expect(text).to include('[VLT-BUILD-SIZE-LIMIT]')
      end
    end

    context 'with large single entry (>= 20MB)' do
      let(:large_entry_zip) { File.join(tmp_dir, 'build', 'artifacts', 'functions', 'ml_fn.zip') }

      before do
        create_test_zip(large_entry_zip, { 'model.bin' => 'x' * 100, 'handler.rb' => 'puts 1' })
      end

      it 'recommends EFS for large individual files' do
        fn_res = double('PackageResult', function_name: 'ml_fn', zip_path: large_entry_zip)

        allow_any_instance_of(Zip::Entry).to receive(:size) do |entry|
          entry.name == 'model.bin' ? 25 * 1024 * 1024 : 100
        end

        report = described_class.analyze(
          app,
          function_results: [fn_res],
          source_dir: tmp_dir
        )

        efs_rec = report.placement_recommendations.find { |r| r['resource'] == 'ml_fn:model.bin' }
        expect(efs_rec).not_to be_nil
        expect(efs_rec['target']).to eq('EFS')
        expect(efs_rec['recommendation']).to include('Large file')
      end
    end
  end

  describe '.format_bytes' do
    it 'formats bytes to human readable units' do
      expect(described_class.format_bytes(500)).to eq('500 B')
      expect(described_class.format_bytes(2048)).to eq('2.0 KB')
      expect(described_class.format_bytes(10 * 1024 * 1024)).to eq('10.0 MB')
      expect(described_class.format_bytes(1024 * 1024 * 1024 * 2)).to eq('2.0 GB')
    end
  end
end
