# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'stringio'

RSpec.describe Veltrunode::Build::Cache::S3Remote do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:bucket) { 'my-test-cache-bucket' }
  let(:prefix) { 'build-cache' }
  let(:content_hash) { 'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0' }
  let(:s3_client) { double('Aws::S3::Client') }

  describe '#key_for' do
    it 'generates key with prefix and extension' do
      remote = described_class.new(bucket: bucket, prefix: 'build-cache', s3_client: s3_client)
      expect(remote.key_for(content_hash, '.zip')).to eq("build-cache/#{content_hash}.zip")
      expect(remote.key_for(content_hash, 'json')).to eq("build-cache/#{content_hash}.json")
    end

    it 'normalizes leading and trailing slashes in prefix' do
      remote = described_class.new(bucket: bucket, prefix: '/caches/nested///', s3_client: s3_client)
      expect(remote.key_for(content_hash, '.zip')).to eq("caches/nested/#{content_hash}.zip")
    end

    it 'generates key without prefix when prefix is nil or empty' do
      remote = described_class.new(bucket: bucket, prefix: nil, s3_client: s3_client)
      expect(remote.key_for(content_hash, '.zip')).to eq("#{content_hash}.zip")

      remote_empty = described_class.new(bucket: bucket, prefix: '   ', s3_client: s3_client)
      expect(remote_empty.key_for(content_hash, '.zip')).to eq("#{content_hash}.zip")
    end
  end

  describe '#store' do
    it 'uploads zip and json to S3' do
      with_tmpdir do |tmpdir|
        zip_path = File.join(tmpdir, 'app.zip')
        json_path = File.join(tmpdir, 'app.json')
        File.binwrite(zip_path, 'fake-zip-payload')
        File.write(json_path, '{"sha256":"dummy"}')

        remote = described_class.new(bucket: bucket, prefix: prefix, s3_client: s3_client)

        expect(s3_client).to receive(:put_object).with(
          bucket: bucket,
          key: "build-cache/#{content_hash}.zip",
          body: instance_of(File)
        )
        expect(s3_client).to receive(:put_object).with(
          bucket: bucket,
          key: "build-cache/#{content_hash}.json",
          body: instance_of(File),
          content_type: 'application/json'
        )

        result = remote.store(content_hash, zip_path, json_path)
        expect(result).to be true
      end
    end

    it 'rescues S3 errors and returns false without raising' do
      with_tmpdir do |tmpdir|
        zip_path = File.join(tmpdir, 'app.zip')
        json_path = File.join(tmpdir, 'app.json')
        File.binwrite(zip_path, 'fake-zip-payload')
        File.write(json_path, '{"sha256":"dummy"}')

        remote = described_class.new(bucket: bucket, prefix: prefix, s3_client: s3_client)

        allow(s3_client).to receive(:put_object).and_raise(RuntimeError.new('AWS network timeout'))

        expect { remote.store(content_hash, zip_path, json_path) }.not_to raise_error
        expect(remote.store(content_hash, zip_path, json_path)).to be false
      end
    end
  end

  describe '#fetch' do
    it 'downloads zip and json, verifies sha256, populates local cache, and copies to output_path' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        output_path = File.join(tmpdir, 'dist', 'function.zip')

        zip_content = 'legitimate-zip-content'
        actual_sha256 = Digest::SHA256.hexdigest(zip_content)
        metadata = {
          'type' => 'function',
          'function_name' => 'convert',
          'sha256' => actual_sha256,
          'bytesize' => zip_content.bytesize,
          'entries' => ['convert.rb']
        }
        json_content = JSON.generate(metadata)

        remote = described_class.new(bucket: bucket, prefix: prefix, s3_client: s3_client)

        # Mock download_s3_file via client.get_object
        allow(s3_client).to receive(:get_object) do |params|
          if params[:key] == "build-cache/#{content_hash}.json"
            File.write(params[:response_target], json_content)
          elsif params[:key] == "build-cache/#{content_hash}.zip"
            File.binwrite(params[:response_target], zip_content)
          end
          double(body: nil)
        end

        result = remote.fetch(content_hash, cache_dir, output_path)

        expect(result).not_to be_nil
        data, sha256 = result
        expect(data).to eq(metadata)
        expect(sha256).to eq(actual_sha256)

        # Verify output_path is populated
        expect(File.exist?(output_path)).to be true
        expect(File.read(output_path)).to eq(zip_content)

        # Verify local cache is populated for future reuse
        expect(File.exist?(File.join(cache_dir, "#{content_hash}.zip"))).to be true
        expect(File.exist?(File.join(cache_dir, "#{content_hash}.json"))).to be true
      end
    end

    it 'detects hash tampering/poisoning and returns nil' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        output_path = File.join(tmpdir, 'dist', 'function.zip')

        tampered_zip_content = 'tampered-or-corrupted-zip-content'
        recorded_sha256 = Digest::SHA256.hexdigest('original-zip-content')
        metadata = {
          'type' => 'function',
          'sha256' => recorded_sha256
        }
        json_content = JSON.generate(metadata)

        remote = described_class.new(bucket: bucket, prefix: prefix, s3_client: s3_client)

        allow(s3_client).to receive(:get_object) do |params|
          if params[:key] == "build-cache/#{content_hash}.json"
            File.write(params[:response_target], json_content)
          elsif params[:key] == "build-cache/#{content_hash}.zip"
            File.binwrite(params[:response_target], tampered_zip_content)
          end
          double(body: nil)
        end

        result = remote.fetch(content_hash, cache_dir, output_path)

        # Hash mismatch detected: fetch must return nil and NOT populate local cache or output
        expect(result).to be_nil
        expect(File.exist?(output_path)).to be false
        expect(File.exist?(File.join(cache_dir, "#{content_hash}.zip"))).to be false
      end
    end

    it 'returns nil gracefully when S3 object does not exist or S3 fails' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        output_path = File.join(tmpdir, 'dist', 'function.zip')

        remote = described_class.new(bucket: bucket, prefix: prefix, s3_client: s3_client)

        err = RuntimeError.new('NoSuchKey: The specified key does not exist.')
        allow(s3_client).to receive(:get_object).and_raise(err)

        expect { remote.fetch(content_hash, cache_dir, output_path) }.not_to raise_error
        expect(remote.fetch(content_hash, cache_dir, output_path)).to be_nil
        expect(File.exist?(output_path)).to be false
      end
    end
  end
end
