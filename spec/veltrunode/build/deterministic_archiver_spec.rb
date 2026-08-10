# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe Veltrunode::Build::DeterministicArchiver do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  describe '.archive' do
    it 'generates a byte-for-byte identical ZIP archive from the same input directory' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'source')
        FileUtils.mkdir_p(File.join(source_dir, 'lib'))

        # Create files in non-alphabetical order and touch with different timestamps
        File.write(File.join(source_dir, 'b.txt'), 'content of b')
        File.write(File.join(source_dir, 'a.txt'), 'content of a')
        File.write(File.join(source_dir, 'lib', 'c.rb'), 'def c; end')

        File.utime(Time.now - 100, Time.now - 100, File.join(source_dir, 'a.txt'))
        File.utime(Time.now - 200, Time.now - 200, File.join(source_dir, 'b.txt'))

        zip1_path = File.join(tmpdir, 'output1.zip')
        zip2_path = File.join(tmpdir, 'output2.zip')

        res1 = described_class.archive(source_dir: source_dir, output_path: zip1_path)
        res2 = described_class.archive(source_dir: source_dir, output_path: zip2_path)

        expect(res1).to be_a(Veltrunode::Build::ArchiveResult)
        expect(res1.sha256).to eq(res2.sha256)
        expect(Digest::SHA256.file(zip1_path).hexdigest).to eq(Digest::SHA256.file(zip2_path).hexdigest)
        expect(File.binread(zip1_path)).to eq(File.binread(zip2_path))

        # Check sorted entries
        expect(res1.entries).to eq(['a.txt', 'b.txt', 'lib', 'lib/c.rb'])
      end
    end

    it 'applies exclude rules correctly' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'source')
        FileUtils.mkdir_p(File.join(source_dir, 'tmp'))

        File.write(File.join(source_dir, 'app.rb'), 'puts "app"')
        File.write(File.join(source_dir, 'app.tmp'), 'temp data')
        File.write(File.join(source_dir, 'tmp', 'cache.txt'), 'cache')

        zip_path = File.join(tmpdir, 'output.zip')

        res = described_class.archive(
          source_dir: source_dir,
          output_path: zip_path,
          excludes: ['tmp/*', '*.tmp']
        )

        expect(res.entries).to contain_exactly('app.rb')

        Zip::File.open(zip_path) do |zipfile|
          entry_names = zipfile.map(&:name)
          expect(entry_names).to contain_exactly('app.rb')
        end
      end
    end

    it 'normalizes timestamps and permissions inside the ZIP archive' do
      with_tmpdir do |tmpdir|
        source_dir = File.join(tmpdir, 'source')
        FileUtils.mkdir_p(source_dir)

        script_path = File.join(source_dir, 'script.sh')
        File.write(script_path, '#!/bin/sh')
        File.chmod(0o755, script_path)

        zip_path = File.join(tmpdir, 'output.zip')
        fixed_time = Time.utc(2024, 1, 1, 0, 0, 0)

        described_class.archive(
          source_dir: source_dir,
          output_path: zip_path,
          fixed_time: fixed_time
        )

        Zip::File.open(zip_path) do |zipfile|
          entry = zipfile.find_entry('script.sh')
          expect(entry).not_to be_nil
          expect(entry.time.strftime('%Y-%m-%d %H:%M:%S')).to eq('2024-01-01 00:00:00')

          unix_perms = (entry.external_file_attributes >> 16) & 0o7777
          expect(unix_perms).to eq(0o755)
        end
      end
    end

    it 'raises ValidationError when source_dir does not exist' do
      expect do
        described_class.archive(source_dir: '/non/existent/dir', output_path: '/tmp/out.zip')
      end.to raise_error(Veltrunode::ValidationError, /Source directory does not exist/)
    end
  end
end
