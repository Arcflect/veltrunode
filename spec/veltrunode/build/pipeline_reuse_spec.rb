# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'veltrunode/build/pipeline'
require 'veltrunode/model/application'
require 'veltrunode/model/function'
require 'veltrunode/model/layer'

RSpec.describe 'Veltrunode::Build::Pipeline layer reuse' do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'common_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64]
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_worker',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      layers: ['common_gems']
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'reuse-test-app',
      stage: 'dev',
      region: 'ap-northeast-1',
      layers: [layer],
      functions: [function]
    )
  end

  let(:sample_lockfile) do
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          json (2.7.1)
      PLATFORMS
        ruby
      DEPENDENCIES
        json
      RUBY VERSION
         ruby 3.3.0p0
      BUNDLED WITH
         2.5.6
    LOCKFILE
  end

  it 'reuses existing layer version from previous manifest when content hash matches' do
    with_tmpdir do |tmpdir|
      lock_path = File.join(tmpdir, 'Gemfile.lock')
      File.write(lock_path, sample_lockfile)
      app_file = File.join(tmpdir, 'app.rb')
      File.write(app_file, 'def handler; end')

      build_dir = File.join(tmpdir, 'build')
      FileUtils.mkdir_p(build_dir)

      # 1. 既存のマニフェストを用意（前回のビルド成果物）
      calculated_hash = Veltrunode::Build::LayerPackager.calculate_hash(
        layer: layer,
        gemfile_lock_path: lock_path,
        source_dir: tmpdir
      )

      manifest_path = File.join(build_dir, 'manifest.json')
      manifest_data = {
        'manifest_schema_version' => '1.0',
        'layers' => {
          'common_gems' => {
            'name' => 'common_gems',
            'content_hash' => calculated_hash,
            'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:7'
          }
        }
      }
      File.write(manifest_path, JSON.generate(manifest_data))

      # 2. パイプラインを実行
      result = Veltrunode::Build::Pipeline.execute(
        application,
        source_dir: tmpdir,
        output_dir: build_dir,
        skip_validation: true,
        check_aws: false
      )

      # 3. 再利用判定結果の検証
      layer_res = result.layer_results.first
      expect(layer_res.reused?).to be true
      expect(layer_res.layer_version_arn).to eq('arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:7')
      expect(layer_res.content_hash).to eq(calculated_hash)

      # ビルドログに出力されていること
      manifest_logged = result.build_logs.any? do |l|
        l.include?('Reusing existing version') && l.include?('via manifest')
      end
      expect(manifest_logged).to be true

      # 4. CloudFormation テンプレートの検証
      # 再利用されたレイヤーはリソース生成がスキップされる
      expect(result.template_data['Resources']).not_to have_key('CommonGemsLayerVersion')

      # 関数の Layers に既存 ARN が直接設定されている
      fn_layers = result.template_data['Resources']['ApiWorkerFunction']['Properties']['Layers']
      expect(fn_layers).to eq(['arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:7'])

      # 関数の DependsOn に LayerVersion が含まれない
      fn_depends = result.template_data['Resources']['ApiWorkerFunction']['DependsOn']
      expect(fn_depends).to eq(['ApiWorkerFunctionLogGroup'])

      # 5. 生成されたマニフェストの検証
      saved_manifest = JSON.parse(File.read(File.join(build_dir, 'manifest.json')))
      layer_manifest = saved_manifest['layers']['common_gems']
      expect(layer_manifest['reused']).to be true
      expect(layer_manifest['layer_version_arn']).to eq(
        'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:7'
      )
      expect(layer_manifest['content_hash']).to eq(calculated_hash)
    end
  end

  it 'publishes new layer version when content hash changes' do
    with_tmpdir do |tmpdir|
      lock_path = File.join(tmpdir, 'Gemfile.lock')
      File.write(lock_path, sample_lockfile)
      app_file = File.join(tmpdir, 'app.rb')
      File.write(app_file, 'def handler; end')

      build_dir = File.join(tmpdir, 'build')
      FileUtils.mkdir_p(build_dir)

      # 古いハッシュのマニフェストが存在
      manifest_path = File.join(build_dir, 'manifest.json')
      manifest_data = {
        'manifest_schema_version' => '1.0',
        'layers' => {
          'common_gems' => {
            'name' => 'common_gems',
            'content_hash' => 'old_outdated_hash_000000000000000000000000000000000000000000',
            'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:1'
          }
        }
      }
      File.write(manifest_path, JSON.generate(manifest_data))

      result = Veltrunode::Build::Pipeline.execute(
        application,
        source_dir: tmpdir,
        output_dir: build_dir,
        skip_validation: true,
        check_aws: false,
        allow_missing_gems: true
      )

      layer_res = result.layer_results.first
      expect(layer_res.reused?).to be false

      # ビルドログに新規発行が出力されていること
      expect(result.build_logs.any? { |l| l.include?('Publishing new version') }).to be true

      # CloudFormation に LayerVersion リソースが生成されていること
      expect(result.template_data['Resources']).to have_key('CommonGemsLayerVersion')

      # 関数の Layers には Ref で設定されること
      fn_layers = result.template_data['Resources']['ApiWorkerFunction']['Properties']['Layers']
      expect(fn_layers).to eq([{ 'Ref' => 'CommonGemsLayerVersion' }])
    end
  end

  it 'reuses existing layer version from AWS description metadata when manifest is missing' do
    with_tmpdir do |tmpdir|
      lock_path = File.join(tmpdir, 'Gemfile.lock')
      File.write(lock_path, sample_lockfile)
      app_file = File.join(tmpdir, 'app.rb')
      File.write(app_file, 'def handler; end')

      build_dir = File.join(tmpdir, 'build')

      calculated_hash = Veltrunode::Build::LayerPackager.calculate_hash(
        layer: layer,
        gemfile_lock_path: lock_path,
        source_dir: tmpdir
      )

      v1 = double(
        'LayerVersion',
        version: 3,
        layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:3',
        description: "Built with Veltrunode hash:#{calculated_hash}"
      )
      resp = double('ListLayerVersionsResponse', layer_versions: [v1])
      aws_client = double('Aws::Lambda::Client')
      allow(aws_client).to receive(:list_layer_versions).and_return(resp)

      result = Veltrunode::Build::Pipeline.execute(
        application,
        source_dir: tmpdir,
        output_dir: build_dir,
        skip_validation: true,
        aws_client: aws_client,
        check_aws: true
      )

      layer_res = result.layer_results.first
      expect(layer_res.reused?).to be true
      expect(layer_res.layer_version_arn).to eq('arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:3')
      expect(result.build_logs.any? { |l| l.include?('via aws_description') }).to be true

      # CloudFormation 側も既存 ARN を参照
      expect(result.template_data['Resources']).not_to have_key('CommonGemsLayerVersion')
      fn_layers = result.template_data['Resources']['ApiWorkerFunction']['Properties']['Layers']
      expect(fn_layers).to eq(['arn:aws:lambda:ap-northeast-1:123456789012:layer:common_gems:3'])
    end
  end

  it 'safely publishes a new version when verification is inconclusive or AWS errors occur' do
    with_tmpdir do |tmpdir|
      lock_path = File.join(tmpdir, 'Gemfile.lock')
      File.write(lock_path, sample_lockfile)
      app_file = File.join(tmpdir, 'app.rb')
      File.write(app_file, 'def handler; end')

      build_dir = File.join(tmpdir, 'build')
      FileUtils.mkdir_p(build_dir)

      # 壊れたマニフェストファイル
      File.write(File.join(build_dir, 'manifest.json'), '{ broken json')

      aws_client = double('Aws::Lambda::Client')
      allow(aws_client).to receive(:list_layer_versions)
        .and_raise(StandardError.new('ServiceUnavailable: 503'))

      result = Veltrunode::Build::Pipeline.execute(
        application,
        source_dir: tmpdir,
        output_dir: build_dir,
        skip_validation: true,
        aws_client: aws_client,
        check_aws: true,
        allow_missing_gems: true
      )

      layer_res = result.layer_results.first
      expect(layer_res.reused?).to be false
      expect(result.template_data['Resources']).to have_key('CommonGemsLayerVersion')
      expect(result.build_logs.any? { |l| l.include?('Publishing new version') }).to be true
    end
  end
end
