# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/layer_version_compiler'
require 'veltrunode/model/layer'

RSpec.describe Veltrunode::Compiler::CloudFormation::LayerVersionCompiler do
  let(:minimal_layer) do
    Veltrunode::Model::Layer.new(
      name: 'runtime_gems',
      compatible_runtimes: %w[ruby3.2 ruby3.3]
    )
  end

  let(:full_layer) do
    Veltrunode::Model::Layer.new(
      name: 'native_tools',
      compatible_runtimes: %w[ruby3.3 ruby3.4],
      architectures: %i[x86_64 arm64],
      description: 'Native tools and utilities',
      license_metadata: { license: 'MIT' }
    )
  end

  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for LayerVersions' do
      expect(described_class.logical_id_for('runtime_gems')).to eq('RuntimeGemsLayerVersion')
      expect(described_class.logical_id_for('runtime_gems_layer_version')).to eq('RuntimeGemsLayerVersion')
      expect(described_class.logical_id_for('common')).to eq('CommonLayerVersion')
      expect(described_class.logical_id_for('')).to eq('LayerVersion')
    end
  end

  describe '#to_h and properties' do
    it 'compiles a minimal layer version with default content reference' do
      result = described_class.compile(minimal_layer)

      expect(result).to have_key('RuntimeGemsLayerVersion')
      resource = result['RuntimeGemsLayerVersion']
      expect(resource['Type']).to eq('AWS::Lambda::LayerVersion')

      props = resource['Properties']
      expect(props['CompatibleRuntimes']).to eq(%w[ruby3.2 ruby3.3])
      expect(props['CompatibleArchitectures']).to eq(['x86_64'])
      expect(props['Content']).to eq({
                                       'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
                                       'S3Key' => 'artifacts/layers/runtime_gems.zip'
                                     })
      expect(props).not_to have_key('Description')
      expect(props).not_to have_key('LicenseInfo')
    end

    it 'compiles a full layer version with description, architectures, and license' do
      result = described_class.compile(full_layer)
      props = result['NativeToolsLayerVersion']['Properties']

      expect(props['CompatibleRuntimes']).to eq(%w[ruby3.3 ruby3.4])
      expect(props['CompatibleArchitectures']).to eq(%w[arm64 x86_64])
      expect(props['Description']).to eq('Native tools and utilities')
      expect(props['LicenseInfo']).to eq('MIT')
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(full_layer)
      resource_keys = result['NativeToolsLayerVersion'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['NativeToolsLayerVersion']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)
    end

    it 'produces deterministic YAML output across multiple compilations' do
      yaml1 = described_class.to_yaml(full_layer)
      yaml2 = described_class.to_yaml(full_layer)

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches expected golden YAML output for full layer version' do
      expected_yaml = <<~YAML
        ---
        NativeToolsLayerVersion:
          Properties:
            CompatibleArchitectures:
            - arm64
            - x86_64
            CompatibleRuntimes:
            - ruby3.3
            - ruby3.4
            Content:
              S3Bucket:
                Ref: ArtifactBucket
              S3Key: artifacts/layers/native_tools.zip
            Description: Native tools and utilities
            LicenseInfo: MIT
          Type: AWS::Lambda::LayerVersion
      YAML

      generated_yaml = described_class.to_yaml(full_layer)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
