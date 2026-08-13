# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Veltrunode::Build::SecretScanner do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  describe '.scan' do
    it 'detects secret files based on filename patterns' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'app.rb'), 'puts "hello"')
        File.write(File.join(tmpdir, '.env'), 'API_KEY=123')
        File.write(File.join(tmpdir, '.env.production'), 'API_KEY=456')
        File.write(File.join(tmpdir, 'id_rsa'), 'private key')
        File.write(File.join(tmpdir, 'server.pem'), 'pem content')
        File.write(File.join(tmpdir, 'credentials.json'), '{"secret": "val"}')

        entries = ['app.rb', '.env', '.env.production', 'id_rsa', 'server.pem', 'credentials.json']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics.size).to eq(5)
        codes = diagnostics.map(&:code)
        expect(codes).to all(eq('VLT-BUILD-SECRET-WARN'))

        detected_files = diagnostics.map { |d| d.evidence['file'] }
        expect(detected_files).to contain_exactly('.env', '.env.production', 'id_rsa', 'server.pem', 'credentials.json')
      end
    end

    it 'detects secret content in text files' do
      with_tmpdir do |tmpdir|
        pem_file = File.join(tmpdir, 'cert.txt')
        aws_file = File.join(tmpdir, 'config.txt')
        key_file = File.join(tmpdir, 'key.txt')

        File.write(pem_file, "-----BEGIN RSA PRIVATE KEY-----\nsecret_data\n-----END RSA PRIVATE KEY-----")
        File.write(aws_file, "AWS_SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY0'")
        File.write(key_file, 'AKIAIOSFODNN7EXAMPLE')

        entries = ['cert.txt', 'config.txt', 'key.txt']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics.size).to eq(3)
        reasons = diagnostics.map { |d| d.evidence['reason'] }
        expect(reasons).to all(eq('sensitive content detected'))
      end
    end

    it 'returns no diagnostics for normal source files' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'app.rb'), 'def run; puts "ok"; end')
        File.write(File.join(tmpdir, 'README.md'), '# Documentation')

        entries = ['app.rb', 'README.md']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics).to be_empty
      end
    end

    it 'skips content scanning for files larger than 1MB' do
      with_tmpdir do |tmpdir|
        large_file = File.join(tmpdir, 'large_log.txt')
        # Create a 1.1MB file containing secret pattern
        content = "AKIAIOSFODNN7EXAMPLE\n#{'a' * 1_100_000}"
        File.write(large_file, content)

        diagnostics = described_class.scan(source_dir: tmpdir, entries: ['large_log.txt'])

        expect(diagnostics).to be_empty
      end
    end

    it 'handles binary files and invalid encodings gracefully' do
      with_tmpdir do |tmpdir|
        binary_file = File.join(tmpdir, 'data.bin')
        File.binwrite(binary_file, "\xFF\xFE\xFD\xFC\xFB\xFA")

        diagnostics = described_class.scan(source_dir: tmpdir, entries: ['data.bin'])

        expect(diagnostics).to be_empty
      end
    end
  end
end
