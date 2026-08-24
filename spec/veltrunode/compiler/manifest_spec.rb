# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Veltrunode::Compiler::Manifest do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:fixed_time) { Time.utc(2026, 8, 24, 22, 0, 0) }

  let(:app) do
    Veltrunode::Model::Application.new(
      name: 'demo-app',
      region: 'ap-northeast-1',
      stage: 'prod',
      account_constraint: '123456789012',
      functions: [
        Veltrunode::Model::Function.new(
          logical_name: 'api_handler',
          handler: 'functions/api.handler',
          runtime: 'ruby3.3',
          architecture: 'arm64',
          memory: 256,
          timeout: 10,
          ephemeral_storage: 512,
          environment: { 'LOG_LEVEL' => 'info' },
          vpc_reference: { security_group_ids: ['sg-12345'], subnet_ids: ['subnet-abc'] },
          layers: ['gem_deps'],
          concurrency: { reserved: 5 },
          logging: { format: 'JSON', level: 'INFO' },
          iam_capabilities: [
            Veltrunode::Model::Capability.new(
              type: :read_from_s3,
              params: { bucket: 'my-data-bucket', prefix: 'export/' }
            )
          ]
        )
      ],
      layers: [
        Veltrunode::Model::Layer.new(
          name: 'gem_deps',
          compatible_runtimes: ['ruby3.3'],
          architectures: ['arm64']
        )
      ],
      schedules: [
        Veltrunode::Model::Schedule.new(
          name: 'nightly_sync',
          target_function: 'api_handler',
          expression_type: :cron,
          expression: 'cron(0 0 * * ? *)',
          timezone: 'Asia/Tokyo',
          state: :enabled,
          flexible_window: { mode: :off },
          retry_policy: { maximum_attempts: 2 }
        )
      ]
    )
  end

  let(:fn_result) do
    Veltrunode::Build::PackageResult.new(
      function_name: 'api_handler',
      zip_path: '/tmp/build/artifacts/functions/api_handler.zip',
      content_hash: 'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0',
      sha256: '9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba',
      bytesize: 1024,
      entries: ['functions/api.rb'],
      diagnostics: []
    )
  end

  let(:layer_result) do
    Veltrunode::Build::LayerPackageResult.new(
      layer_name: 'gem_deps',
      zip_path: '/tmp/build/artifacts/layers/gem_deps.zip',
      content_hash: 'f0e1d2c3b4a59876543210fedcba9876543210fedcba9876543210fedcba9876',
      sha256: '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff',
      compressed_size: 2048,
      uncompressed_size: 4096,
      size_diagnostics: { compressed_size: 2048, uncompressed_size: 4096 },
      entries: ['ruby/gems/3.3.0/gems/json-2.7.1'],
      diagnostics: []
    )
  end

  describe '.build_data and .to_h' do
    it 'builds complete manifest structure with required sections and metadata' do
      manifest = described_class.to_h(
        application: app,
        function_results: [fn_result],
        layer_results: [layer_result],
        built_at: fixed_time
      )

      expect(manifest['manifest_schema_version']).to eq('1.0')
      expect(manifest['schema_version']).to eq('1.0')
      expect(manifest['compiler_version']).to eq(Veltrunode::VERSION)
      expect(manifest['built_at']).to eq('2026-08-24T22:00:00Z')

      # Application
      expect(manifest['application']).to eq({
                                              'account_constraint' => '123456789012',
                                              'name' => 'demo-app',
                                              'region' => 'ap-northeast-1',
                                              'stage' => 'prod'
                                            })

      # Functions
      fn_data = manifest['functions']['api_handler']
      expect(fn_data['logical_name']).to eq('api_handler')
      expect(fn_data['handler']).to eq('functions/api.handler')
      expect(fn_data['runtime']).to eq('ruby3.3')
      expect(fn_data['architecture']).to eq('arm64')
      expect(fn_data['memory']).to eq(256)
      expect(fn_data['timeout']).to eq(10)
      expect(fn_data['vpc_reference']).to eq({ 'security_group_ids' => ['sg-12345'], 'subnet_ids' => ['subnet-abc'] })
      expect(fn_data['layers']).to eq(['gem_deps'])
      expect(fn_data['concurrency']).to eq({ 'reserved' => 5 })
      expect(fn_data['logging']).to eq({ 'format' => 'JSON', 'level' => 'INFO' })
      expect(fn_data['content_hash']).to eq(fn_result.content_hash)
      expect(fn_data['sha256']).to eq(fn_result.sha256)
      expect(fn_data['artifact_hash']).to eq(fn_result.sha256)
      expect(fn_data['zip_path']).to eq('api_handler.zip')

      # Layers
      layer_data = manifest['layers']['gem_deps']
      expect(layer_data['name']).to eq('gem_deps')
      expect(layer_data['compatible_runtimes']).to eq(['ruby3.3'])
      expect(layer_data['architectures']).to eq(['arm64'])
      expect(layer_data['content_hash']).to eq(layer_result.content_hash)
      expect(layer_data['sha256']).to eq(layer_result.sha256)
      expect(layer_data['artifact_hash']).to eq(layer_result.sha256)
      expect(layer_data['zip_path']).to eq('gem_deps.zip')

      # Schedules
      sch_data = manifest['schedules']['nightly_sync']
      expect(sch_data['name']).to eq('nightly_sync')
      expect(sch_data['target_function']).to eq('api_handler')
      expect(sch_data['expression_type']).to eq('cron')
      expect(sch_data['expression']).to eq('cron(0 0 * * ? *)')
      expect(sch_data['timezone']).to eq('Asia/Tokyo')
      expect(sch_data['state']).to eq('enabled')

      # IAM Capabilities
      iam_stmts = manifest['iam_capabilities']['api_handler']
      expect(iam_stmts).to be_an(Array)
      expect(iam_stmts.first['Effect']).to eq('Allow')
      expect(iam_stmts.first['Action']).to include('s3:GetObject')
    end

    it 'recursively sorts keys in the output map for determinism' do
      manifest = described_class.to_h(
        application: app,
        function_results: [fn_result],
        layer_results: [layer_result],
        built_at: fixed_time
      )

      top_keys = manifest.keys
      expect(top_keys).to eq(top_keys.sort)

      app_keys = manifest['application'].keys
      expect(app_keys).to eq(app_keys.sort)

      fn_keys = manifest['functions']['api_handler'].keys
      expect(fn_keys).to eq(fn_keys.sort)
    end

    it 'redacts SecretValue instances in function environment variables to [FILTERED]' do
      secret_fn = Veltrunode::Model::Function.new(
        logical_name: 'secret_fn',
        handler: 'fn.handler',
        environment: {
          'PUBLIC_KEY' => 'public_val',
          'SECRET_TOKEN' => Veltrunode::DSL::SecretValue.new('super_secret_password')
        }
      )
      secret_app = Veltrunode::Model::Application.new(name: 'sec-app', functions: [secret_fn])

      manifest = described_class.to_h(application: secret_app, built_at: fixed_time)
      env_data = manifest['functions']['secret_fn']['environment']

      expect(env_data['PUBLIC_KEY']).to eq('public_val')
      expect(env_data['SECRET_TOKEN']).to eq('[FILTERED]')
    end
  end

  describe '.to_json' do
    it 'returns valid formatted JSON string' do
      json_str = described_class.to_json(
        application: app,
        function_results: [fn_result],
        layer_results: [layer_result],
        built_at: fixed_time
      )

      parsed = JSON.parse(json_str)
      expect(parsed['manifest_schema_version']).to eq('1.0')
      expect(parsed['application']['name']).to eq('demo-app')
    end
  end

  describe '.generate' do
    it 'writes manifest.json to specified file path and returns manifest hash' do
      with_tmpdir do |tmpdir|
        manifest_path = File.join(tmpdir, 'build', 'manifest.json')
        result = described_class.generate(
          application: app,
          output_path: manifest_path,
          function_results: [fn_result],
          layer_results: [layer_result],
          built_at: fixed_time
        )

        expect(File.exist?(manifest_path)).to be true
        content = File.read(manifest_path)
        parsed = JSON.parse(content)

        expect(parsed['manifest_schema_version']).to eq('1.0')
        expect(parsed['application']['name']).to eq('demo-app')
        expect(result['application']['name']).to eq('demo-app')
      end
    end
  end
end
