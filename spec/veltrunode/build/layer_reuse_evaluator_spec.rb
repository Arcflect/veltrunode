# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'veltrunode/build/layer_reuse_evaluator'
require 'veltrunode/model/layer'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::Build::LayerReuseEvaluator do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'ruby_gems',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64]
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

  describe '#evaluate' do
    context 'when manifest contains matching content hash and valid ARN' do
      it 'decides to reuse existing layer version from manifest' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          expected_hash = Veltrunode::Build::LayerPackager.calculate_hash(
            layer: layer,
            gemfile_lock_path: lock_path,
            source_dir: tmpdir
          )

          manifest_dir = File.join(tmpdir, 'build')
          FileUtils.mkdir_p(manifest_dir)
          manifest_path = File.join(manifest_dir, 'manifest.json')
          manifest_content = {
            'manifest_schema_version' => '1.0',
            'layers' => {
              'ruby_gems' => {
                'name' => 'ruby_gems',
                'content_hash' => expected_hash,
                'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:2'
              }
            }
          }
          File.write(manifest_path, JSON.generate(manifest_content))

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: manifest_path,
            check_aws: false
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be true
          expect(decision.layer_name).to eq('ruby_gems')
          expect(decision.content_hash).to eq(expected_hash)
          expect(decision.layer_version_arn).to eq('arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:2')
          expect(decision.source).to eq(:manifest)
          expect(decision.reason).to include('found in manifest')
        end
      end
    end

    context 'when manifest does not match but AWS Layer description metadata matches' do
      it 'decides to reuse existing layer version from AWS description' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          expected_hash = Veltrunode::Build::LayerPackager.calculate_hash(
            layer: layer,
            gemfile_lock_path: lock_path,
            source_dir: tmpdir
          )

          v1 = double(
            'LayerVersion',
            version: 1,
            layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:1',
            description: 'old build hash:999999999999'
          )
          v2 = double(
            'LayerVersion',
            version: 2,
            layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:2',
            description: "Built by Veltrunode [hash:#{expected_hash}]"
          )
          list_resp = double('ListLayerVersionsResponse', layer_versions: [v2, v1])

          aws_client = double('Aws::Lambda::Client')
          allow(aws_client).to receive(:list_layer_versions)
            .with(layer_name: anything)
            .and_return(list_resp)

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: File.join(tmpdir, 'non_existent_manifest.json'),
            aws_client: aws_client,
            check_aws: true
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be true
          expect(decision.layer_name).to eq('ruby_gems')
          expect(decision.content_hash).to eq(expected_hash)
          expect(decision.layer_version_arn).to eq('arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:2')
          expect(decision.version).to eq(2)
          expect(decision.source).to eq(:aws_description)
          expect(decision.reason).to include('AWS layer version 2 description')
        end
      end
    end

    context 'when content hash does not match' do
      it 'decides to publish a new version' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          manifest_dir = File.join(tmpdir, 'build')
          FileUtils.mkdir_p(manifest_dir)
          manifest_path = File.join(manifest_dir, 'manifest.json')
          manifest_content = {
            'layers' => {
              'ruby_gems' => {
                'name' => 'ruby_gems',
                'content_hash' => 'different_hash_0000000000000000000000000000000000000000',
                'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:1'
              }
            }
          }
          File.write(manifest_path, JSON.generate(manifest_content))

          v1 = double(
            'LayerVersion',
            version: 1,
            layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:ruby_gems:1',
            description: 'hash:different_hash_0000000000000000000000000000000000000000'
          )
          list_resp = double('ListLayerVersionsResponse', layer_versions: [v1])
          aws_client = double('Aws::Lambda::Client')
          allow(aws_client).to receive(:list_layer_versions).and_return(list_resp)

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: manifest_path,
            aws_client: aws_client,
            check_aws: true
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be false
          expect(decision.source).to eq(:none)
          expect(decision.layer_version_arn).to be_nil
          expect(decision.reason).to include('Publishing new version')
        end
      end
    end

    context 'when verification is inconclusive (safe fallback principle)' do
      it 'safely falls back to publishing new version when manifest is corrupted' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          manifest_path = File.join(tmpdir, 'corrupted_manifest.json')
          File.write(manifest_path, '{ invalid json content }')

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: manifest_path,
            check_aws: false
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be false
          expect(decision.source).to eq(:none)
          expect(decision.reason).to include('Publishing new version')
        end
      end

      it 'safely falls back to publishing new version when manifest ARN is missing or invalid' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          expected_hash = Veltrunode::Build::LayerPackager.calculate_hash(
            layer: layer,
            gemfile_lock_path: lock_path,
            source_dir: tmpdir
          )

          manifest_path = File.join(tmpdir, 'manifest.json')
          manifest_content = {
            'layers' => {
              'ruby_gems' => {
                'name' => 'ruby_gems',
                'content_hash' => expected_hash,
                'layer_version_arn' => 'not-a-valid-arn'
              }
            }
          }
          File.write(manifest_path, JSON.generate(manifest_content))

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: manifest_path,
            check_aws: false
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be false
        end
      end

      it 'safely falls back to publishing new version when AWS API throws an error' do
        with_tmpdir do |tmpdir|
          lock_path = File.join(tmpdir, 'Gemfile.lock')
          File.write(lock_path, sample_lockfile)

          aws_client = double('Aws::Lambda::Client')
          allow(aws_client).to receive(:list_layer_versions)
            .and_raise(StandardError.new('AccessDeniedException: User is not authorized'))

          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            manifest_path: File.join(tmpdir, 'non_existent.json'),
            aws_client: aws_client,
            check_aws: true
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be false
          expect(decision.reason).to include('Publishing new version')
        end
      end

      it 'safely falls back to publishing new version when content hash calculation fails' do
        with_tmpdir do |tmpdir|
          # Gemfile.lock not present
          evaluator = described_class.new(
            layer: layer,
            source_dir: tmpdir,
            check_manifest: false,
            check_aws: false
          )

          decision = evaluator.evaluate
          expect(decision.reusable?).to be false
          expect(decision.content_hash).to be_nil
          expect(decision.reason).to include('Failed to calculate layer content hash')
        end
      end
    end

    context 'with explicit content_hash passed' do
      it 'uses provided content hash without recalculating' do
        manifest_path = '/tmp/fake_manifest.json'
        evaluator = described_class.new(
          layer: layer,
          content_hash: 'preset_hash_123',
          manifest_path: manifest_path,
          check_manifest: false,
          check_aws: false
        )

        decision = evaluator.evaluate
        expect(decision.content_hash).to eq('preset_hash_123')
        expect(decision.reusable?).to be false
      end
    end
  end
end
