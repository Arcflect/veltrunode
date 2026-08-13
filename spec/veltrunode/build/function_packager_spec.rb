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

    it 'validates handler file existence and raises ValidationError with VLT-BUILD-001 when missing' do
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
          expect(err.diagnostics.first.code).to eq('VLT-BUILD-001')
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
          expect(err.diagnostics.first.code).to eq('VLT-BUILD-001')
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
  end
end
