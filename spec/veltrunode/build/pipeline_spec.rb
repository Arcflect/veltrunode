# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'veltrunode/build/pipeline'
require 'veltrunode/model/application'
require 'veltrunode/model/function'
require 'veltrunode/model/layer'

RSpec.describe Veltrunode::Build::Pipeline do
  let(:tmp_dir) { Dir.mktmpdir('veltrunode-pipeline-test-') }
  let(:output_dir) { File.join(tmp_dir, 'build') }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'runtime_gems',
      compatible_runtimes: %w[ruby3.2 ruby3.3]
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_func',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      layers: ['runtime_gems']
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'pipeline-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      functions: [function],
      layers: [layer]
    )
  end

  let(:mock_layer_result) do
    instance_double(
      Veltrunode::Build::LayerPackageResult,
      layer_name: 'runtime_gems',
      zip_path: File.join(output_dir, 'artifacts', 'layers', 'runtime_gems.zip'),
      sha256: 'layer_sha256_hash',
      content_hash: 'layer_content_hash',
      bytesize: 5000,
      cached?: false,
      diagnostics: []
    )
  end

  let(:mock_function_result) do
    instance_double(
      Veltrunode::Build::PackageResult,
      function_name: 'api_func',
      zip_path: File.join(output_dir, 'artifacts', 'functions', 'api_func.zip'),
      sha256: 'func_sha256_hash',
      content_hash: 'func_content_hash',
      bytesize: 2500,
      cached?: false,
      diagnostics: []
    )
  end

  before do
    allow(Veltrunode::Build::LayerPackager).to receive(:package).and_return(mock_layer_result)
    allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_return(mock_function_result)
    allow(Veltrunode::Compiler::CloudFormation).to receive(:generate).and_call_original
    allow(Veltrunode::Compiler::Manifest).to receive(:generate).and_call_original
  end

  describe '.execute' do
    it 'runs full build pipeline: validation, packaging, CFn template compilation, manifest generation' do
      result = described_class.execute(
        application,
        source_dir: tmp_dir,
        output_dir: output_dir,
        no_cache: false
      )

      expect(result).to be_a(Veltrunode::Build::BuildResult)
      expect(result.functions_count).to eq(1)
      expect(result.layers_count).to eq(1)
      expect(result.template_path).to eq(File.join(output_dir, 'template.yml'))
      expect(result.manifest_path).to eq(File.join(output_dir, 'manifest.json'))

      expect(File.exist?(result.template_path)).to be true
      expect(File.exist?(result.manifest_path)).to be true

      template_content = File.read(result.template_path)
      expect(YAML.safe_load(template_content)['AWSTemplateFormatVersion']).to eq('2010-09-09')
      expect(template_content).to include('ApiFuncFunction:')

      manifest_content = JSON.parse(File.read(result.manifest_path))
      expect(manifest_content['application']['name']).to eq('pipeline-app')
      expect(manifest_content['functions']['api_func']['sha256']).to eq('func_sha256_hash')
      expect(manifest_content['layers']['runtime_gems']['sha256']).to eq('layer_sha256_hash')

      expect(Veltrunode::Build::LayerPackager).to have_received(:package).with(
        layer: layer,
        source_dir: tmp_dir,
        output_dir: File.join(output_dir, 'artifacts', 'layers'),
        no_cache: false
      )

      expect(Veltrunode::Build::FunctionPackager).to have_received(:package).with(
        function: function,
        source_dir: tmp_dir,
        output_dir: File.join(output_dir, 'artifacts', 'functions'),
        no_cache: false
      )
    end

    it 'passes no_cache: true to packagers when specified' do
      described_class.execute(
        application,
        source_dir: tmp_dir,
        output_dir: output_dir,
        no_cache: true
      )

      expect(Veltrunode::Build::LayerPackager).to have_received(:package).with(
        hash_including(no_cache: true)
      )
      expect(Veltrunode::Build::FunctionPackager).to have_received(:package).with(
        hash_including(no_cache: true)
      )
    end

    it 'aborts and raises ValidationError when validation fails with error diagnostics' do
      invalid_fn = Veltrunode::Model::Function.new(
        logical_name: 'invalid_fn',
        handler: 'app.handler',
        runtime: 'ruby2.7', # Incompatible with layer runtime ruby3.2/ruby3.3
        layers: ['runtime_gems']
      )
      invalid_app = Veltrunode::Model::Application.new(
        name: 'invalid-app',
        functions: [invalid_fn],
        layers: [layer]
      )

      error = nil
      begin
        described_class.execute(
          invalid_app,
          source_dir: tmp_dir,
          output_dir: output_dir
        )
      rescue Veltrunode::ValidationError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.diagnostics).not_to be_empty
      expect(error.diagnostics.map(&:code)).to include('VLT-LAYER-001')

      expect(Veltrunode::Build::LayerPackager).not_to have_received(:package)
      expect(Veltrunode::Build::FunctionPackager).not_to have_received(:package)
    end

    it 'raises BuildError with exit_code 5 when unexpected packaging error occurs' do
      allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_raise(RuntimeError, 'Zip creation failed')

      error = nil
      begin
        described_class.execute(
          application,
          source_dir: tmp_dir,
          output_dir: output_dir
        )
      rescue Veltrunode::Build::BuildError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.message).to include('Zip creation failed')
      expect(error.exit_code).to eq(5)
    end

    it 'formats structured artifacts and JSON representation in BuildResult' do
      result = described_class.execute(
        application,
        source_dir: tmp_dir,
        output_dir: output_dir
      )

      data = result.to_h
      expect(data['status']).to eq('success')
      expect(data['functions_count']).to eq(1)
      expect(data['layers_count']).to eq(1)
      expect(data['template_path']).to eq(File.join(output_dir, 'template.yml'))
      expect(data['manifest_path']).to eq(File.join(output_dir, 'manifest.json'))

      artifacts = data['artifacts']
      expect(artifacts['functions'].first).to eq({
                                                   'name' => 'api_func',
                                                   'zip_path' => File.join(output_dir, 'artifacts', 'functions',
                                                                           'api_func.zip'),
                                                   'sha256' => 'func_sha256_hash',
                                                   'content_hash' => 'func_content_hash',
                                                   'bytesize' => 2500,
                                                   'cached' => false
                                                 })
      expect(artifacts['layers'].first).to eq({
                                                'name' => 'runtime_gems',
                                                'zip_path' => File.join(output_dir, 'artifacts', 'layers',
                                                                        'runtime_gems.zip'),
                                                'sha256' => 'layer_sha256_hash',
                                                'content_hash' => 'layer_content_hash',
                                                'bytesize' => 5000,
                                                'cached' => false
                                              })
      expect(artifacts['template']).to eq({ 'path' => File.join(output_dir, 'template.yml') })
      expect(artifacts['manifest']).to eq({ 'path' => File.join(output_dir, 'manifest.json') })
    end
  end
end
