# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe Veltrunode::Build::LayerPackager do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'dependencies',
      compatible_runtimes: ['ruby3.3'],
      architectures: [:x86_64]
    )
  end

  let(:sample_lockfile_content) do
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          faraday (2.9.0)
          json (2.7.1)
          rake (13.1.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        faraday
        json
        rake

      RUBY VERSION
         ruby 3.3.0p0

      BUNDLED WITH
         2.5.6
    LOCKFILE
  end

  describe '.package' do
    it 'packages gems into ruby/gems/<ruby_version>/ structure and returns LayerPackageResult' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        output_dir = File.join(tmpdir, 'build', 'artifacts', 'layers')

        result = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: output_dir,
          allow_missing_gems: true
        )

        expect(result).to be_a(Veltrunode::Build::LayerPackageResult)
        expect(result.layer_name).to eq('dependencies')
        expect(result.zip_path).to eq(File.join(output_dir, 'dependencies.zip'))
        expect(File.exist?(result.zip_path)).to be true
        expect(result.sha256).to eq(Digest::SHA256.file(result.zip_path).hexdigest)
        expect(result.digest).to eq(result.sha256)
        expect(result.bytesize).to eq(File.size(result.zip_path))
        expect(result.content_hash).not_to be_empty

        # Check entries for ruby/gems/3.3.0/ directory structure
        gemspec_entries = result.entries.select { |e| e.start_with?('ruby/gems/3.3.0/specifications/') }
        expect(gemspec_entries).to include(
          'ruby/gems/3.3.0/specifications/faraday-2.9.0.gemspec',
          'ruby/gems/3.3.0/specifications/json-2.7.1.gemspec',
          'ruby/gems/3.3.0/specifications/rake-13.1.0.gemspec'
        )

        Zip::File.open(result.zip_path) do |zipfile|
          entry_names = zipfile.map(&:name)
          expect(entry_names).to include(
            'ruby/',
            'ruby/gems/',
            'ruby/gems/3.3.0/',
            'ruby/gems/3.3.0/gems/faraday-2.9.0/',
            'ruby/gems/3.3.0/specifications/faraday-2.9.0.gemspec'
          )
        end
      end
    end

    it 'copies and includes actual gem payload files into the ZIP archive when gems are available' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        gem_payload = File.join(tmpdir, 'gems', 'json-2.7.1', 'lib', 'json.rb')
        FileUtils.mkdir_p(File.dirname(gem_payload))
        File.write(gem_payload, 'module JSON; VERSION = "2.7.1"; end')

        output_dir = File.join(tmpdir, 'out')

        result = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: output_dir,
          allow_missing_gems: true
        )

        expected_payload_entry = 'ruby/gems/3.3.0/gems/json-2.7.1/lib/json.rb'
        expect(result.entries).to include(expected_payload_entry)

        Zip::File.open(result.zip_path) do |zipfile|
          entry = zipfile.find_entry(expected_payload_entry)
          expect(entry).not_to be_nil
          expect(zipfile.read(entry)).to eq('module JSON; VERSION = "2.7.1"; end')
        end
      end
    end

    it 'filters gems according to include_gems rule' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        output_dir = File.join(tmpdir, 'out')

        result = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: output_dir,
          include_gems: ['json'],
          allow_missing_gems: true
        )

        expect(result.entries).to include('ruby/gems/3.3.0/specifications/json-2.7.1.gemspec')
        expect(result.entries).not_to include('ruby/gems/3.3.0/specifications/faraday-2.9.0.gemspec')
        expect(result.entries).not_to include('ruby/gems/3.3.0/specifications/rake-13.1.0.gemspec')
      end
    end

    it 'calculates size diagnostics including compressed/uncompressed sizes and largest entries' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        result = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out'),
          allow_missing_gems: true
        )

        expect(result.compressed_size).to be > 0
        expect(result.uncompressed_size).to be >= 0

        diag = result.size_diagnostics
        expect(diag[:compressed_size]).to eq(result.compressed_size)
        expect(diag[:uncompressed_size]).to eq(result.uncompressed_size)
        expect(diag[:entry_count]).to be > 0
        expect(diag[:largest_entries]).to be_an(Array)
      end
    end

    it 'computes deterministic content_hash based on inputs and produces identical ZIP files' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        out1 = File.join(tmpdir, 'out1')
        out2 = File.join(tmpdir, 'out2')

        res1 = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: out1,
          allow_missing_gems: true
        )
        res2 = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: out2,
          allow_missing_gems: true
        )

        expect(res1.content_hash).to eq(res2.content_hash)
        expect(res1.sha256).to eq(res2.sha256)
        expect(File.binread(res1.zip_path)).to eq(File.binread(res2.zip_path))
      end
    end

    it 'changes content_hash when build inputs change' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        res1 = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out1'),
          without_groups: %w[development],
          allow_missing_gems: true
        )

        res2 = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out2'),
          without_groups: %w[development test],
          allow_missing_gems: true
        )

        expect(res1.content_hash).not_to eq(res2.content_hash)
      end
    end

    it 'excludes gems belonging to without_groups when Gemfile defines groups' do
      with_tmpdir do |tmpdir|
        gemfile_path = File.join(tmpdir, 'Gemfile')
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')

        File.write(gemfile_path, <<~GEMFILE)
          source 'https://rubygems.org'
          gem 'json', '2.7.1'

          group :development, :test do
            gem 'rake', '13.1.0'
          end
        GEMFILE

        File.write(lockfile_path, sample_lockfile_content)

        result = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out'),
          without_groups: %w[development test],
          allow_missing_gems: true
        )

        expect(result.entries).to include('ruby/gems/3.3.0/specifications/json-2.7.1.gemspec')
        expect(result.entries).not_to include('ruby/gems/3.3.0/specifications/rake-13.1.0.gemspec')
      end
    end

    it 'raises ValidationError when Gemfile.lock does not exist' do
      with_tmpdir do |tmpdir|
        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: File.join(tmpdir, 'non_existent.lock'),
            output_dir: File.join(tmpdir, 'out')
          )
        end.to raise_error(Veltrunode::ValidationError, /Gemfile.lock not found/)
      end
    end

    it 'raises ValidationError when Gemfile.lock content is invalid' do
      with_tmpdir do |tmpdir|
        invalid_lock = File.join(tmpdir, 'Gemfile.lock')
        File.write(invalid_lock, "INVALID LOCK FILE CONTENT\n  :::bad_syntax:::")

        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: invalid_lock,
            output_dir: File.join(tmpdir, 'out')
          )
        end.to raise_error(Veltrunode::ValidationError, /Failed to parse Gemfile.lock/)
      end
    end

    it 'raises ValidationError when gem directory cannot be found locally and allow_missing_gems is false' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: lockfile_path,
            source_dir: tmpdir,
            output_dir: File.join(tmpdir, 'out'),
            allow_missing_gems: false
          )
        end.to raise_error(Veltrunode::ValidationError, /Gem content not found/)
      end
    end

    it 'raises ValidationError when copying gem directory fails' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        gem_dir = File.join(tmpdir, 'gems', 'json-2.7.1')
        FileUtils.mkdir_p(gem_dir)

        allow(FileUtils).to receive(:cp_r).and_raise(Errno::EACCES, 'Permission denied')

        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: lockfile_path,
            source_dir: tmpdir,
            output_dir: File.join(tmpdir, 'out'),
            include_gems: ['json']
          )
        end.to raise_error(Veltrunode::ValidationError, /Failed to copy gem/)
      end
    end

    it 'raises ValidationError when layer contents contain a symlink pointing outside layer directory' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        secret_file = File.join(tmpdir, 'secret.txt')
        File.write(secret_file, 'sensitive data')

        gem_dir = File.join(tmpdir, 'gems', 'json-2.7.1')
        FileUtils.mkdir_p(gem_dir)
        File.symlink(secret_file, File.join(gem_dir, 'leak.txt'))

        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: lockfile_path,
            source_dir: tmpdir,
            output_dir: File.join(tmpdir, 'out'),
            include_gems: ['json']
          )
        end.to raise_error(Veltrunode::ValidationError, /Symlink points outside layer contents/)
      end
    end

    it 'raises ValidationError when layer contents contain a broken symlink' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        gem_dir = File.join(tmpdir, 'gems', 'json-2.7.1')
        FileUtils.mkdir_p(gem_dir)
        File.symlink(File.join(tmpdir, 'non_existent_file.txt'), File.join(gem_dir, 'broken.txt'))

        expect do
          described_class.package(
            layer: layer,
            gemfile_lock_path: lockfile_path,
            source_dir: tmpdir,
            output_dir: File.join(tmpdir, 'out'),
            include_gems: ['json']
          )
        end.to raise_error(Veltrunode::ValidationError, /Broken symlink found in layer contents/)
      end
    end

    it 'triggers container build when build_on is specified and reflects image digest in content_hash' do
      with_tmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, sample_lockfile_content)

        mock_native_builder = class_double(Veltrunode::Build::NativeBuilder)
        expect(mock_native_builder).to receive(:build).with(
          hash_including(build_on: :amazon_linux_2023) # rubocop:disable Naming/VariableNumber
        ).and_return(image_digest: 'sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210')

        res_native = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out1'),
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          native_builder: mock_native_builder,
          allow_missing_gems: true
        )

        res_plain = described_class.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: File.join(tmpdir, 'out2'),
          allow_missing_gems: true
        )

        expect(res_native.content_hash).not_to eq(res_plain.content_hash)
      end
    end
  end
end
