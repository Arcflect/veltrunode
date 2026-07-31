# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Function do
  let(:valid_attributes) do
    {
      logical_name: 'my_function',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      architecture: :x86_64,
      memory: 512,
      timeout: 30,
      ephemeral_storage: 1024,
      environment: { 'LOG_LEVEL' => 'info' },
      vpc_reference: 'vpc-12345',
      layers: ['shared_layer'],
      mounts: [{ name: 'data_mount', local_path: '/mnt/data' }],
      iam_capabilities: ['s3:GetObject'],
      concurrency: 10,
      logging: { format: 'JSON' }
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:fn) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(fn.logical_name).to eq('my_function')
        expect(fn.handler).to eq('app.handler')
        expect(fn.runtime).to eq('ruby3.3')
        expect(fn.architecture).to eq(:x86_64)
        expect(fn.memory).to eq(512)
        expect(fn.timeout).to eq(30)
        expect(fn.ephemeral_storage).to eq(1024)
        expect(fn.environment).to eq({ 'LOG_LEVEL' => 'info' })
        expect(fn.vpc_reference).to eq('vpc-12345')
        expect(fn.layers).to eq(['shared_layer'])
        expect(fn.mounts).to eq([{ 'name' => 'data_mount', 'local_path' => '/mnt/data' }])
        expect(fn.iam_capabilities).to eq(['s3:GetObject'])
        expect(fn.concurrency).to eq(10)
        expect(fn.logging).to eq({ 'format' => 'JSON' })
      end

      it 'provides default values for optional attributes' do
        minimal_fn = described_class.new(logical_name: 'minimal')
        expect(minimal_fn.architecture).to eq(:x86_64)
        expect(minimal_fn.memory).to eq(128)
        expect(minimal_fn.timeout).to eq(3)
        expect(minimal_fn.ephemeral_storage).to eq(512)
        expect(minimal_fn.environment).to eq({})
        expect(minimal_fn.layers).to eq([])
        expect(minimal_fn.mounts).to eq([])
        expect(minimal_fn.iam_capabilities).to eq([])
      end
    end

    context 'immutability' do
      subject(:fn) { described_class.new(**valid_attributes) }

      it 'freezes the instance and its collections' do
        expect(fn).to be_frozen
        expect(fn.logical_name).to be_frozen
        expect(fn.environment).to be_frozen
        expect(fn.layers).to be_frozen
        expect(fn.mounts).to be_frozen
        expect(fn.iam_capabilities).to be_frozen
      end

      it 'prevents modification of environment and collections' do
        expect { fn.environment['KEY'] = 'VAL' }.to raise_error(FrozenError)
        expect { fn.layers << 'another_layer' }.to raise_error(FrozenError)
      end
    end

    context 'validation' do
      it 'raises ValidationError when logical_name is missing or empty' do
        expect { described_class.new(logical_name: nil) }
          .to raise_error(Veltrunode::ValidationError, /logical_name/)
        expect { described_class.new(logical_name: '') }
          .to raise_error(Veltrunode::ValidationError, /logical_name/)
        expect { described_class.new(logical_name: '   ') }
          .to raise_error(Veltrunode::ValidationError, /logical_name/)
      end
    end
  end

  describe '#validate_invariants' do
    let(:context) do
      {
        available_layer_names: ['shared_layer'],
        available_mount_names: ['data_mount'],
        layers: [{ name: 'shared_layer', architectures: %i[x86_64 arm64] }]
      }
    end

    context 'when all invariants are satisfied' do
      it 'returns no diagnostics' do
        fn = described_class.new(**valid_attributes)
        diagnostics = fn.validate_invariants(context)
        expect(diagnostics).to be_empty
      end
    end

    context 'Invariant 1: Timeout (1..900s)' do
      it 'allows timeout of 1s and 900s' do
        fn1 = described_class.new(logical_name: 'fn1', timeout: 1)
        fn900 = described_class.new(logical_name: 'fn900', timeout: 900)

        expect(fn1.validate_invariants).to be_empty
        expect(fn900.validate_invariants).to be_empty
      end

      it 'creates a Diagnostic when timeout is 0 or less' do
        fn = described_class.new(logical_name: 'fn', timeout: 0)
        diagnostics = fn.validate_invariants

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-DSL-TIMEOUT')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['timeout']).to eq(0)
      end

      it 'creates a Diagnostic when timeout exceeds 900s' do
        fn = described_class.new(logical_name: 'fn', timeout: 901)
        diagnostics = fn.validate_invariants

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-DSL-TIMEOUT')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['timeout']).to eq(901)
      end
    end

    context 'Invariant 2: Mount paths start with /mnt/' do
      it 'allows mount paths starting with /mnt/' do
        fn = described_class.new(
          logical_name: 'fn',
          mounts: [{ name: 'm1', local_path: '/mnt/efs1' }, '/mnt/efs2']
        )
        ctx = { available_mount_names: ['m1', '/mnt/efs2'] }

        expect(fn.validate_invariants(ctx)).to be_empty
      end

      it 'creates a Diagnostic when mount path does not start with /mnt/' do
        fn = described_class.new(
          logical_name: 'fn',
          mounts: [{ name: 'm1', local_path: '/tmp/data' }]
        )
        ctx = { available_mount_names: ['m1'] }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-EFS-PATH')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['local_path']).to eq('/tmp/data')
      end

      it 'does not treat plain mount reference names as invalid paths' do
        fn = described_class.new(
          logical_name: 'fn',
          mounts: ['shared']
        )
        ctx = { available_mount_names: ['shared'] }
        expect(fn.validate_invariants(ctx)).to be_empty
      end
    end

    context 'Invariant 3: Architecture compatibility with attached layers' do
      it 'allows matching architecture' do
        fn = described_class.new(
          logical_name: 'fn',
          architecture: :arm64,
          layers: ['arm_layer']
        )
        ctx = {
          available_layer_names: ['arm_layer'],
          layers: [{ name: 'arm_layer', architectures: [:arm64] }]
        }

        expect(fn.validate_invariants(ctx)).to be_empty
      end

      it 'creates a Diagnostic when layer architecture is incompatible' do
        fn = described_class.new(
          logical_name: 'fn',
          architecture: :arm64,
          layers: ['x86_only_layer']
        )
        ctx = {
          available_layer_names: ['x86_only_layer'],
          layers: [{ name: 'x86_only_layer', architectures: [:x86_64] }]
        }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-LAYER-001')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['function_architecture']).to eq('arm64')
      end
    end

    context 'Invariant 4: Existence of referenced layers and mounts' do
      it 'creates a Diagnostic when referenced layer does not exist' do
        fn = described_class.new(logical_name: 'fn', layers: ['missing_layer'])
        ctx = { available_layer_names: ['existing_layer'] }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-REF-001')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['missing_layer']).to eq('missing_layer')
      end

      it 'normalizes symbol references when checking existence' do
        fn = described_class.new(logical_name: 'fn', layers: [:missing_layer])
        ctx = { available_layer_names: ['existing_layer'] }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.evidence['missing_layer']).to eq('missing_layer')
      end

      it 'creates a Diagnostic when referenced mount does not exist' do
        fn = described_class.new(
          logical_name: 'fn',
          mounts: [{ name: 'missing_mount', local_path: '/mnt/missing' }]
        )
        ctx = { available_mount_names: ['existing_mount'] }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-REF-001')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['missing_mount']).to eq('missing_mount')
      end

      it 'extracts name from name:/path mount reference format' do
        fn = described_class.new(
          logical_name: 'fn',
          mounts: ['existing_mount:/mnt/data']
        )
        ctx = { available_mount_names: ['existing_mount'] }
        expect(fn.validate_invariants(ctx)).to be_empty
      end
    end

    context 'Invariant 5: No duplicate environment keys after stage merge' do
      it 'creates a Diagnostic when duplicate environment keys are detected' do
        fn = described_class.new(
          logical_name: 'fn',
          environment: { 'STAGE' => 'dev', 'PORT' => '8080' }
        )
        ctx = { stage_environment: { 'STAGE' => 'dev' } }
        diagnostics = fn.validate_invariants(ctx)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-DSL-ENV')
        expect(diag.severity).to eq(:error)
        expect(diag.evidence['duplicate_key']).to eq('STAGE')
      end
    end

    describe '#validate_invariants!' do
      it 'raises ValidationError containing diagnostics when invariants fail' do
        fn = described_class.new(logical_name: 'fn', timeout: 0)

        expect { fn.validate_invariants! }
          .to raise_error(Veltrunode::ValidationError) { |error|
            expect(error.diagnostics).not_to be_empty
            expect(error.diagnostics.first.code).to eq('VLT-DSL-TIMEOUT')
          }
      end

      it 'does not raise error when invariants pass' do
        fn = described_class.new(**valid_attributes)
        expect { fn.validate_invariants!(context) }.not_to raise_error
      end
    end
  end
end
