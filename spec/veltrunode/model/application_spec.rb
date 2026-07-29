# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Application do
  let(:valid_attributes) do
    {
      name: 'my-app',
      region: 'ap-northeast-1',
      stage: 'production',
      account_constraint: '123456789012',
      runtime_defaults: { ruby: '3.3' },
      functions: ['fn1'],
      layers: ['layer1'],
      schedules: ['sched1'],
      mounts: ['mount1'],
      policies: ['policy1'],
      tags: { Environment: 'production' }
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:app) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(app.name).to eq('my-app')
        expect(app.region).to eq('ap-northeast-1')
        expect(app.stage).to eq('production')
        expect(app.account_constraint).to eq('123456789012')
        expect(app.runtime_defaults).to eq({ ruby: '3.3' })
        expect(app.functions).to eq(['fn1'])
        expect(app.layers).to eq(['layer1'])
        expect(app.schedules).to eq(['sched1'])
        expect(app.mounts).to eq(['mount1'])
        expect(app.policies).to eq(['policy1'])
        expect(app.tags).to eq({ Environment: 'production' })
      end

      it 'provides default empty values for omitted optional attributes' do
        minimal_app = described_class.new(name: 'app', region: 'us-east-1', stage: 'dev')
        expect(minimal_app.account_constraint).to be_nil
        expect(minimal_app.runtime_defaults).to eq({})
        expect(minimal_app.functions).to eq([])
        expect(minimal_app.layers).to eq([])
        expect(minimal_app.schedules).to eq([])
        expect(minimal_app.mounts).to eq([])
        expect(minimal_app.policies).to eq([])
        expect(minimal_app.tags).to eq({})
      end
    end

    context 'immutability' do
      subject(:app) { described_class.new(**valid_attributes) }

      it 'freezes the instance' do
        expect(app).to be_frozen
      end

      it 'freezes string and collection attributes' do
        expect(app.name).to be_frozen
        expect(app.region).to be_frozen
        expect(app.stage).to be_frozen
        expect(app.account_constraint).to be_frozen
        expect(app.runtime_defaults).to be_frozen
        expect(app.functions).to be_frozen
        expect(app.layers).to be_frozen
        expect(app.schedules).to be_frozen
        expect(app.mounts).to be_frozen
        expect(app.policies).to be_frozen
        expect(app.tags).to be_frozen
      end

      it 'prevents modification of collection attributes' do
        expect { app.functions << 'fn2' }.to raise_error(FrozenError)
        expect { app.tags[:Key] = 'Value' }.to raise_error(FrozenError)
      end
    end

    context 'validation' do
      it 'raises ValidationError when name is missing or empty' do
        expect { described_class.new(name: nil, region: 'us-east-1', stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /name/)
        expect { described_class.new(name: '', region: 'us-east-1', stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /name/)
        expect { described_class.new(name: '   ', region: 'us-east-1', stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /name/)
      end

      it 'raises ValidationError when region is missing or empty' do
        expect { described_class.new(name: 'app', region: nil, stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /region/)
        expect { described_class.new(name: 'app', region: '', stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /region/)
        expect { described_class.new(name: 'app', region: '   ', stage: 'dev') }
          .to raise_error(Veltrunode::ValidationError, /region/)
      end

      it 'raises ValidationError when stage is missing or empty' do
        expect { described_class.new(name: 'app', region: 'us-east-1', stage: nil) }
          .to raise_error(Veltrunode::ValidationError, /stage/)
        expect { described_class.new(name: 'app', region: 'us-east-1', stage: '') }
          .to raise_error(Veltrunode::ValidationError, /stage/)
        expect { described_class.new(name: 'app', region: 'us-east-1', stage: '   ') }
          .to raise_error(Veltrunode::ValidationError, /stage/)
      end

      it 'ensures ValidationError inherits from Veltrunode::Error' do
        expect(Veltrunode::ValidationError.ancestors).to include(Veltrunode::Error)
      end
    end
  end
end
