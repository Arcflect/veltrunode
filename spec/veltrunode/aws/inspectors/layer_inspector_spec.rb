# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'zip'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/layer_inspector'

RSpec.describe Veltrunode::AWS::Inspectors::LayerInspector do
  let(:tmp_dir) { Dir.mktmpdir('layer_inspector_spec_') }

  let(:layer_hash) { nil }
  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'gem_layer',
      compatible_runtimes: %w[ruby3.3 ruby3.2],
      architectures: %i[x86_64 arm64],
      description: 'Test gem layer',
      content_hash: layer_hash
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      :worker,
      handler: 'app.handler',
      runtime: 'ruby3.3'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'layer-test-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      layers: [layer],
      functions: [function]
    )
  end

  # Helper to create a dummy ZIP file with entries
  def create_test_zip(path, entries)
    FileUtils.mkdir_p(File.dirname(path))
    Zip::File.open(path, create: true) do |zip|
      entries.each do |entry_path, content|
        zip.get_output_stream(entry_path) { |f| f.write(content) }
      end
    end
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe '.inspect' do
    let(:layer_zip_path) { File.join(tmp_dir, 'build', 'artifacts', 'layers', 'gem_layer.zip') }

    before do
      # Create sample layer zip with small and large entries
      create_test_zip(layer_zip_path, {
                        'ruby/gems/3.3.0/gems/nokogiri-1.16.0/ports/libxml2.a' => 'A' * 10_000,
                        'ruby/gems/3.3.0/gems/grpc-1.60.0/grpc_c.so' => 'B' * 5_000,
                        'ruby/gems/3.3.0/gems/json-2.7.1/lib/json.rb' => 'C' * 1_000,
                        'ruby/gems/3.3.0/gems/json-2.7.1/lib/json/common.rb' => 'D' * 500
                      })
    end

    context 'with mock AWS client returning published versions' do
      let(:mock_client) { double('Aws::Lambda::Client') }
      let(:mock_versions_response) do
        v3 = double(
          'LayerVersion',
          version: 3,
          layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:layer-test-app-gem_layer:3',
          created_date: '2026-10-01T10:00:00Z',
          description: 'hash:sample_content_hash_123',
          compatible_runtimes: ['ruby3.3'],
          compatible_architectures: ['x86_64']
        )
        v2 = double(
          'LayerVersion',
          version: 2,
          layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:layer-test-app-gem_layer:2',
          created_date: '2026-09-20T08:00:00Z',
          description: 'hash:old_hash_999',
          compatible_runtimes: ['ruby3.3'],
          compatible_architectures: ['x86_64']
        )
        double('ListLayerVersionsResponse', layer_versions: [v3, v2])
      end

      before do
        allow(mock_client).to receive(:list_layer_versions).and_return(mock_versions_response)
      end

      context 'when content hash matches published version' do
        let(:layer_hash) { 'sample_content_hash_123' }

        it 'calculates size, largest entries, and reports reuse status' do
          report = described_class.inspect(
            application,
            layer_name: 'gem_layer',
            source_dir: tmp_dir,
            aws_client: mock_client
          )

          expect(report.layer_name).to eq('gem_layer')
          expect(report.description).to eq('Test gem layer')
          expect(report.compatible_runtimes).to eq(%w[ruby3.3 ruby3.2])
          expect(report.architectures).to eq(%w[x86_64 arm64])
          expect(report.content_hash).to eq('sample_content_hash_123')
          expect(report.sha256).to be_a(String)
          expect(report.compressed_size).to be > 0
          expect(report.uncompressed_size).to eq(16_500)
          expect(report.total_entries).to eq(4)

          # Largest entries
          expect(report.largest_entries.size).to eq(4)
          first_entry = report.largest_entries.first
          expect(first_entry['path']).to include('libxml2.a')
          expect(first_entry['size']).to eq(10_000)
          expect(first_entry['percentage']).to eq(60.6)

          # Published versions
          expect(report.published_versions.size).to eq(2)
          expect(report.published_versions.first['version']).to eq(3)

          # Reuse evaluation
          expect(report.reusable?).to be(true)
          expect(report.matched_version).to eq(3)
          expect(report.matched_arn).to include('layer:layer-test-app-gem_layer:3')
          expect(report.reuse_reason).to include('Matching content hash')
        end
      end

      context 'when content hash does not match any published version' do
        let(:layer_hash) { 'different_new_hash_456' }

        it 'reports reusable: false' do
          report = described_class.inspect(
            application,
            layer_name: 'gem_layer',
            source_dir: tmp_dir,
            aws_client: mock_client
          )

          expect(report.reusable?).to be(false)
          expect(report.matched_version).to be_nil
          expect(report.reuse_reason).to include('No published version matches current content hash')
        end
      end
    end

    context 'when no published versions exist on AWS' do
      let(:mock_client) { double('Aws::Lambda::Client') }
      let(:empty_response) { double('ListLayerVersionsResponse', layer_versions: []) }

      before do
        allow(mock_client).to receive(:list_layer_versions).and_return(empty_response)
      end

      it 'reports reusable: false with appropriate reason' do
        report = described_class.inspect(
          application,
          layer_name: 'gem_layer',
          source_dir: tmp_dir,
          aws_client: mock_client
        )

        expect(report.published_versions).to be_empty
        expect(report.reusable?).to be(false)
        expect(report.reuse_reason).to include('No published versions found on AWS')
      end
    end

    context 'duplicate files detection across functions and layers' do
      it 'detects duplicate files in vendor directory of function source' do
        # Create a duplicated file inside vendor/bundle in source_dir
        dup_file = File.join(tmp_dir, 'vendor', 'bundle', 'ruby', '3.3.0', 'gems', 'json-2.7.1', 'lib', 'json.rb')
        FileUtils.mkdir_p(File.dirname(dup_file))
        File.write(dup_file, 'C' * 1_000)

        report = described_class.inspect(
          application,
          layer_name: 'gem_layer',
          source_dir: tmp_dir,
          fetch_remote: false
        )

        expect(report.duplicate_files).not_to be_empty
        dup = report.duplicate_files.first
        expect(dup['path']).to include('json.rb')
        expect(dup['duplicated_in']).to include('function:worker')
        expect(dup['recommendation']).to include('Exclude')
      end

      it 'detects duplicate files across other layers' do
        # Add another layer to application
        other_layer = Veltrunode::Model::Layer.new(
          name: 'other_layer',
          compatible_runtimes: ['ruby3.3']
        )
        app_with_two_layers = Veltrunode::Model::Application.new(
          name: 'two-layers-app',
          region: 'ap-northeast-1',
          stage: 'dev',
          layers: [layer, other_layer]
        )

        # Create zip for other_layer containing overlapping file
        other_zip_path = File.join(tmp_dir, 'build', 'artifacts', 'layers', 'other_layer.zip')
        create_test_zip(other_zip_path, {
                          'ruby/gems/3.3.0/gems/json-2.7.1/lib/json.rb' => 'C' * 1_000
                        })

        report = described_class.inspect(
          app_with_two_layers,
          layer_name: 'gem_layer',
          source_dir: tmp_dir,
          fetch_remote: false
        )

        dup = report.duplicate_files.find { |d| d['duplicated_in'].include?('layer:other_layer') }
        expect(dup).not_to be_nil
        expect(dup['path']).to eq('ruby/gems/3.3.0/gems/json-2.7.1/lib/json.rb')
        expect(dup['recommendation']).to include('Consolidate into a single shared layer')
      end
    end

    context 'error handling' do
      it 'raises ArgumentError if layer does not exist in application' do
        expect do
          described_class.inspect(application, layer_name: 'non_existent', source_dir: tmp_dir)
        end.to raise_error(ArgumentError, /Layer 'non_existent' not found/)
      end
    end

    context 'Report#to_h serialization' do
      it 'converts to a complete structured hash for json output' do
        report = described_class.inspect(
          application,
          layer_name: 'gem_layer',
          source_dir: tmp_dir,
          fetch_remote: false
        )

        hash = report.to_h
        expect(hash['layer_name']).to eq('gem_layer')
        expect(hash['description']).to eq('Test gem layer')
        expect(hash['compatible_runtimes']).to eq(%w[ruby3.3 ruby3.2])
        expect(hash['architectures']).to eq(%w[x86_64 arm64])
        expect(hash['size']['uncompressed_bytes']).to eq(16_500)
        expect(hash['reuse']).to be_a(Hash)
        expect(hash['largest_entries']).to be_an(Array)
        expect(hash['duplicate_files']).to be_an(Array)
      end
    end
  end
end
