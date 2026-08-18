# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Veltrunode::Build::Cache do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:content_hash) { 'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0' }

  describe '#store and #fetch' do
    it 'stores PackageResult into cache and restores it on fetch with cached: true' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        source_zip = File.join(tmpdir, 'convert.zip')
        File.write(source_zip, 'dummy zip content')

        result = Veltrunode::Build::PackageResult.new(
          function_name: 'convert',
          zip_path: source_zip,
          content_hash: content_hash,
          sha256: Digest::SHA256.file(source_zip).hexdigest,
          bytesize: File.size(source_zip),
          entries: ['functions/convert.rb'],
          diagnostics: []
        )

        cache = described_class.new(cache_dir: cache_dir)
        cache.store(content_hash, result)

        expect(File.exist?(File.join(cache_dir, "#{content_hash}.zip"))).to be true
        expect(File.exist?(File.join(cache_dir, "#{content_hash}.json"))).to be true

        dest_zip = File.join(tmpdir, 'out', 'convert.zip')
        restored = cache.fetch(content_hash, dest_zip)

        expect(restored).not_to be_nil
        expect(restored).to be_a(Veltrunode::Build::PackageResult)
        expect(restored.function_name).to eq('convert')
        expect(restored.zip_path).to eq(dest_zip)
        expect(restored.content_hash).to eq(content_hash)
        expect(restored.sha256).to eq(result.sha256)
        expect(restored.bytesize).to eq(result.bytesize)
        expect(restored.entries).to eq(['functions/convert.rb'])
        expect(restored.cached?).to be true
        expect(File.read(dest_zip)).to eq('dummy zip content')
      end
    end

    it 'stores LayerPackageResult into cache and restores it on fetch with cached: true' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        source_zip = File.join(tmpdir, 'gems.zip')
        File.write(source_zip, 'layer zip payload')

        layer_result = Veltrunode::Build::LayerPackageResult.new(
          layer_name: 'gems',
          zip_path: source_zip,
          content_hash: content_hash,
          sha256: Digest::SHA256.file(source_zip).hexdigest,
          compressed_size: File.size(source_zip),
          uncompressed_size: 100,
          size_diagnostics: { compressed_size: File.size(source_zip), uncompressed_size: 100 },
          entries: ['ruby/gems/3.3.0/gems/json-2.7.1'],
          diagnostics: []
        )

        cache = described_class.new(cache_dir: cache_dir)
        cache.store(content_hash, layer_result)

        dest_zip = File.join(tmpdir, 'out', 'gems.zip')
        restored = cache.fetch(content_hash, dest_zip)

        expect(restored).not_to be_nil
        expect(restored).to be_a(Veltrunode::Build::LayerPackageResult)
        expect(restored.layer_name).to eq('gems')
        expect(restored.zip_path).to eq(dest_zip)
        expect(restored.content_hash).to eq(content_hash)
        expect(restored.sha256).to eq(layer_result.sha256)
        expect(restored.compressed_size).to eq(layer_result.compressed_size)
        expect(restored.cached?).to be true
      end
    end

    it 'returns nil when fetching non-existent content_hash' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        cache = described_class.new(cache_dir: cache_dir)

        dest_zip = File.join(tmpdir, 'out', 'nonexistent.zip')
        expect(cache.fetch('a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef9', dest_zip)).to be_nil
      end
    end

    it 'rejects invalid non-hex keys or path traversal attempts defensively' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        cache = described_class.new(cache_dir: cache_dir)

        dest_zip = File.join(tmpdir, 'out', 'dest.zip')
        expect(cache.fetch('../path/traversal', dest_zip)).to be_nil
        expect(cache.fetch('short_hash', dest_zip)).to be_nil

        result = instance_double(Veltrunode::Build::PackageResult, zip_path: dest_zip)
        expect(cache.store('../path/traversal', result)).to be_nil
      end
    end

    it 'detects cache poisoning / corrupted zip, invalidates cache and returns nil' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        source_zip = File.join(tmpdir, 'convert.zip')
        File.write(source_zip, 'original zip content')

        result = Veltrunode::Build::PackageResult.new(
          function_name: 'convert',
          zip_path: source_zip,
          content_hash: content_hash,
          sha256: Digest::SHA256.file(source_zip).hexdigest,
          bytesize: File.size(source_zip),
          entries: ['functions/convert.rb'],
          diagnostics: []
        )

        cache = described_class.new(cache_dir: cache_dir)
        cache.store(content_hash, result)

        # Corrupt the cached zip file (simulating cache poisoning)
        cache_zip_path = File.join(cache_dir, "#{content_hash}.zip")
        File.write(cache_zip_path, 'TAMPERED / CORRUPTED ZIP CONTENT')

        dest_zip = File.join(tmpdir, 'out', 'convert.zip')
        restored = cache.fetch(content_hash, dest_zip)

        # Fetch should fail, returning nil
        expect(restored).to be_nil
        # Corrupted cache entry should be removed
        expect(File.exist?(cache_zip_path)).to be false
        expect(File.exist?(File.join(cache_dir, "#{content_hash}.json"))).to be false
      end
    end
  end

  describe '#clear' do
    it 'removes the cache directory and all its contents' do
      with_tmpdir do |tmpdir|
        cache_dir = File.join(tmpdir, 'cache')
        FileUtils.mkdir_p(cache_dir)
        File.write(File.join(cache_dir, 'test.tmp'), 'data')

        cache = described_class.new(cache_dir: cache_dir)
        cache.clear

        expect(File.exist?(cache_dir)).to be false
      end
    end
  end
end
