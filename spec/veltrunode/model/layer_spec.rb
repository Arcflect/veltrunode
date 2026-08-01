# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Layer do
  let(:valid_attributes) do
    {
      name: 'gems_layer',
      compatible_runtimes: ['ruby3.3', 'ruby3.2'],
      source_spec: 'vendor/bundle',
      architectures: %i[x86_64 arm64],
      build_environment: { 'BUNDLER_VERSION' => '2.5.0' },
      retention_policy: { latest: 3 },
      description: 'Common Ruby gems layer',
      license_metadata: 'MIT',
      content_hash: 'a1b2c3d4e5f67890'
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:layer) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(layer.name).to eq('gems_layer')
        expect(layer.compatible_runtimes).to eq(['ruby3.3', 'ruby3.2'])
        expect(layer.source_spec).to eq('vendor/bundle')
        expect(layer.architectures).to eq(%i[x86_64 arm64])
        expect(layer.build_environment).to eq({ 'BUNDLER_VERSION' => '2.5.0' })
        expect(layer.retention_policy).to eq({ latest: 3 })
        expect(layer.description).to eq('Common Ruby gems layer')
        expect(layer.license_metadata).to eq('MIT')
        expect(layer.content_hash).to eq('a1b2c3d4e5f67890')
      end

      it 'provides default values for optional attributes' do
        minimal_layer = described_class.new(name: 'minimal', compatible_runtimes: ['ruby3.3'])

        expect(minimal_layer.source_spec).to be_nil
        expect(minimal_layer.architectures).to eq([:x86_64])
        expect(minimal_layer.build_environment).to eq({})
        expect(minimal_layer.retention_policy).to eq({ latest: 5 })
        expect(minimal_layer.description).to be_nil
        expect(minimal_layer.license_metadata).to be_nil
        expect(minimal_layer.content_hash).to be_nil
      end

      it 'supports string and symbol keys in retention_policy' do
        layer = described_class.new(
          name: 'layer',
          compatible_runtimes: ['ruby3.3'],
          retention_policy: { 'latest' => 10 }
        )
        expect(layer.retention_policy).to eq({ latest: 10 })
      end

      it "does not allow duplicate :latest and 'latest' keys to override the validated value" do
        layer = described_class.new(
          name: 'layer',
          compatible_runtimes: ['ruby3.3'],
          retention_policy: { latest: 7, 'latest' => 99 }
        )
        expect(layer.retention_policy).to eq({ latest: 7 })
      end
    end

    context 'immutability' do
      subject(:layer) { described_class.new(**valid_attributes) }

      it 'freezes the instance and its collections' do
        expect(layer).to be_frozen
        expect(layer.name).to be_frozen
        expect(layer.compatible_runtimes).to be_frozen
        expect(layer.architectures).to be_frozen
        expect(layer.build_environment).to be_frozen
        expect(layer.retention_policy).to be_frozen
      end

      it 'prevents modification of attributes' do
        expect { layer.compatible_runtimes << 'ruby3.1' }.to raise_error(FrozenError)
        expect { layer.build_environment['ENV'] = 'test' }.to raise_error(FrozenError)
      end
    end

    context 'validation' do
      it 'raises ValidationError when name is missing or empty' do
        expect { described_class.new(name: nil, compatible_runtimes: ['ruby3.3']) }
          .to raise_error(Veltrunode::ValidationError, /name/)
        expect { described_class.new(name: '', compatible_runtimes: ['ruby3.3']) }
          .to raise_error(Veltrunode::ValidationError, /name/)
        expect { described_class.new(name: '   ', compatible_runtimes: ['ruby3.3']) }
          .to raise_error(Veltrunode::ValidationError, /name/)
      end

      it 'raises ValidationError when compatible_runtimes is missing or empty' do
        expect { described_class.new(name: 'layer', compatible_runtimes: nil) }
          .to raise_error(Veltrunode::ValidationError, /compatible_runtimes/)
        expect { described_class.new(name: 'layer', compatible_runtimes: []) }
          .to raise_error(Veltrunode::ValidationError, /compatible_runtimes/)
      end

      it 'raises ValidationError when retention_policy latest is invalid' do
        expect do
          described_class.new(
            name: 'layer',
            compatible_runtimes: ['ruby3.3'],
            retention_policy: { latest: 0 }
          )
        end.to raise_error(Veltrunode::ValidationError, /latest/)

        expect do
          described_class.new(
            name: 'layer',
            compatible_runtimes: ['ruby3.3'],
            retention_policy: { latest: -1 }
          )
        end.to raise_error(Veltrunode::ValidationError, /latest/)

        expect do
          described_class.new(
            name: 'layer',
            compatible_runtimes: ['ruby3.3'],
            retention_policy: { latest: 'invalid' }
          )
        end.to raise_error(Veltrunode::ValidationError, /latest/)
      end
    end
  end
end
