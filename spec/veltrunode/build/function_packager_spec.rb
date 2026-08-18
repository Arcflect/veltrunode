# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe Veltrunode::Build::FunctionPackager do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'convert',
      handler: 'functions/convert.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.package' do
    it 'packages the function source into build/artifacts/functions/<name>.zip and returns PackageResult' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'def handler(event:, context:); end')

        output_dir = File.join(tmpdir, 'build', 'artifacts', 'functions')

        result = described_class.package(
          function: function,
          source_dir: source_dir,
          output_dir: output_dir
        )

        expect(result).to be_a(Veltrunode::Build::PackageResult)
        expect(result.function_name).to eq('convert')
        expect(result.zip_path).to eq(File.join(output_dir, 'convert.zip'))
        expect(File.exist?(result.zip_path)).to be true
        expect(result.sha256).to eq(Digest::SHA256.file(result.zip_path).hexdigest)
        expect(result.digest).to eq(result.sha256)
        expect(result.entries).to contain_exactly('functions', 'functions/convert.rb')
        expect(result.diagnostics).to be_empty

        Zip::File.open(result.zip_path) do |zipfile|
          expect(zipfile.map(&:name)).to contain_exactly('functions/', 'functions/convert.rb')
        end
      end
    end

    it 'excludes test and development files by default' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        FileUtils.mkdir_p(File.join(source_dir, 'spec'))
        FileUtils.mkdir_p(File.join(source_dir, 'tmp'))

        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "code"')
        File.write(File.join(source_dir, 'spec', 'convert_spec.rb'), 'puts "test"')
        File.write(File.join(source_dir, 'tmp', 'debug.tmp'), 'temp')

        output_dir = File.join(tmpdir, 'output')

        result = described_class.package(
          function: function,
          source_dir: source_dir,
          output_dir: output_dir
        )

        expect(result.entries).to contain_exactly('functions', 'functions/convert.rb')
      end
    end

    it 'validates handler file existence and raises ValidationError with VLT-BUILD-HANDLER-NOT-FOUND when missing' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(source_dir)
        # Missing functions/convert.rb

        expect do
          described_class.package(
            function: function,
            source_dir: source_dir,
            output_dir: File.join(tmpdir, 'out')
          )
        end.to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-BUILD-HANDLER-NOT-FOUND')
          expect(err.diagnostics.first.evidence['function']).to eq('convert')
          expect(err.diagnostics.first.evidence['expected_files']).to include('functions/convert.rb')
        }
      end
    end

    it 'prevents path traversal outside source_dir during handler validation' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(source_dir)

        # Create outside_handler.rb outside source_dir
        File.write(File.join(tmpdir, 'outside_handler.rb'), 'puts "outside"')

        traversal_fn = Veltrunode::Model::Function.new(
          logical_name: 'traversal_fn',
          handler: '../outside_handler.handler',
          runtime: 'ruby3.3'
        )

        expect do
          described_class.package(
            function: traversal_fn,
            source_dir: source_dir,
            output_dir: File.join(tmpdir, 'out')
          )
        end.to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics.first.code).to eq('VLT-BUILD-HANDLER-NOT-FOUND')
        }
      end
    end

    it 'scans for secret files and generates warning diagnostics when detected' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))

        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "code"')
        File.write(File.join(source_dir, '.env'), 'SECRET_KEY=supersecret')

        output_dir = File.join(tmpdir, 'out')

        result = described_class.package(
          function: function,
          source_dir: source_dir,
          output_dir: output_dir,
          includes: ['.env', 'functions/**/*']
        )

        warn_diag = result.diagnostics.find { |d| d.code == 'VLT-BUILD-SECRET-WARN' }
        expect(warn_diag).not_to be_nil
        expect(warn_diag.severity).to eq(:warning)
        expect(warn_diag.evidence['file']).to eq('.env')
      end
    end

    it 'produces byte-for-byte identical ZIP packages for identical source inputs' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "hello"')

        out1 = File.join(tmpdir, 'out1')
        out2 = File.join(tmpdir, 'out2')

        res1 = described_class.package(function: function, source_dir: source_dir, output_dir: out1)
        res2 = described_class.package(function: function, source_dir: source_dir, output_dir: out2)

        expect(res1.sha256).to eq(res2.sha256)
        expect(File.binread(res1.zip_path)).to eq(File.binread(res2.zip_path))
      end
    end

    it 'raises ValidationError with VLT-BUILD-SYMLINK-TRAVERSAL when a symlink points outside source_dir' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "code"')

        outside_secret = File.join(tmpdir, 'secret_system_file')
        File.write(outside_secret, 'secret')

        # Symlink pointing outside source_dir
        File.symlink(outside_secret, File.join(source_dir, 'link_to_secret'))

        expect do
          described_class.package(
            function: function,
            source_dir: source_dir,
            output_dir: File.join(tmpdir, 'out')
          )
        end.to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics.first.code).to eq('VLT-BUILD-SYMLINK-TRAVERSAL')
          expect(err.diagnostics.first.evidence['symlink']).to eq('link_to_secret')
        }
      end
    end

    it 'computes deterministic content_hash based on function config and source files' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "hello"')

        packager1 = described_class.new(function: function, source_dir: source_dir)
        hash1 = packager1.calculate_content_hash

        packager2 = described_class.new(function: function, source_dir: source_dir)
        hash2 = packager2.calculate_content_hash

        expect(hash1).to eq(hash2)
        expect(hash1).not_to be_empty

        # Modify source file
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "hello world"')
        packager3 = described_class.new(function: function, source_dir: source_dir)
        hash3 = packager3.calculate_content_hash

        expect(hash3).not_to eq(hash1)
      end
    end

    it 'skips zipping on cache hit and restores artifact from local cache' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "cached code"')

        output_dir1 = File.join(tmpdir, 'out1')
        output_dir2 = File.join(tmpdir, 'out2')

        res1 = described_class.package(function: function, source_dir: source_dir, output_dir: output_dir1)
        expect(res1.cached?).to be false
        expect(File.exist?(res1.zip_path)).to be true

        res2 = described_class.package(function: function, source_dir: source_dir, output_dir: output_dir2)
        expect(res2.cached?).to be true
        expect(res2.content_hash).to eq(res1.content_hash)
        expect(res2.sha256).to eq(res1.sha256)
        expect(File.exist?(res2.zip_path)).to be true
        expect(File.binread(res2.zip_path)).to eq(File.binread(res1.zip_path))
      end
    end

    it 'bypasses cache when no_cache: true option is provided' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "nocache"')

        out1 = File.join(tmpdir, 'out1')
        out2 = File.join(tmpdir, 'out2')

        res1 = described_class.package(function: function, source_dir: source_dir, output_dir: out1)
        expect(res1.cached?).to be false

        res2 = described_class.package(function: function, source_dir: source_dir, output_dir: out2, no_cache: true)
        expect(res2.cached?).to be false
      end
    end

    it 'rebuilds artifact when cached artifact hash is corrupted (cache poisoning protection)' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'src')
        FileUtils.mkdir_p(File.join(source_dir, 'functions'))
        File.write(File.join(source_dir, 'functions', 'convert.rb'), 'puts "poison test"')

        out1 = File.join(tmpdir, 'out1')
        out2 = File.join(tmpdir, 'out2')

        res1 = described_class.package(function: function, source_dir: source_dir, output_dir: out1)
        expect(res1.cached?).to be false

        # Corrupt cached zip in .veltrunode/cache
        cached_zip = File.join(source_dir, '.veltrunode', 'cache', "#{res1.content_hash}.zip")
        File.write(cached_zip, 'CORRUPTED PAYLOAD')

        res2 = described_class.package(function: function, source_dir: source_dir, output_dir: out2)
        expect(res2.cached?).to be false
        expect(res2.sha256).to eq(res1.sha256)
      end
    end
  end
end
