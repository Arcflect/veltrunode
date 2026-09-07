# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Veltrunode::Build::SecretScanner do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  describe '.calculate_shannon_entropy' do
    it 'returns 0.0 for empty or nil string' do
      expect(described_class.calculate_shannon_entropy('')).to eq(0.0)
      expect(described_class.calculate_shannon_entropy(nil)).to eq(0.0)
    end

    it 'returns 0.0 for repeated single character strings' do
      expect(described_class.calculate_shannon_entropy('aaaaa')).to eq(0.0)
    end

    it 'calculates correct positive entropy for diverse strings' do
      entropy = described_class.calculate_shannon_entropy('d8F9ax83Lq4b72MzA1p9V0kLmNoPqRsT')
      expect(entropy).to be > 4.2
    end
  end

  describe '.scan' do
    it 'detects all required secret file patterns (.env, .env.*, *.pem, *.key, id_rsa, credentials, *.secret)' do
      with_tmpdir do |tmpdir|
        filenames = [
          '.env',
          '.env.local',
          '.env.production',
          'server.pem',
          'private.key',
          'id_rsa',
          'credentials',
          'app.secret',
          'config.secret',
          'credentials.json',
          'secrets.yml'
        ]

        filenames.each do |fn|
          File.write(File.join(tmpdir, fn), 'dummy content')
        end
        File.write(File.join(tmpdir, 'normal_app.rb'), 'puts "hello"')

        entries = filenames + ['normal_app.rb']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics.size).to eq(filenames.size)
        codes = diagnostics.map(&:code)
        expect(codes).to all(eq('VLT-BUILD-SECRET-WARN'))
        expect(diagnostics.map(&:severity)).to all(eq(:warning))

        detected_files = diagnostics.map { |d| d.evidence['file'] }
        expect(detected_files).to match_array(filenames)
        expect(diagnostics.map { |d| d.evidence['reason'] }).to all(eq('sensitive file pattern'))
      end
    end

    it 'detects secret content patterns in text files' do
      with_tmpdir do |tmpdir|
        pem_file = File.join(tmpdir, 'cert.txt')
        aws_file = File.join(tmpdir, 'config.txt')
        key_file = File.join(tmpdir, 'key.txt')

        File.write(pem_file, "-----BEGIN RSA PRIVATE KEY-----
secret_data
-----END RSA PRIVATE KEY-----")
        File.write(aws_file, "AWS_SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY0'")
        File.write(key_file, 'AKIAIOSFODNN7EXAMPLE')

        entries = ['cert.txt', 'config.txt', 'key.txt']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics.size).to eq(3)
        reasons = diagnostics.map { |d| d.evidence['reason'] }
        expect(reasons).to all(eq('sensitive content detected'))
        expect(diagnostics.map(&:severity)).to all(eq(:warning))
      end
    end

    it 'detects high-entropy strings (e.g. API keys, random secret tokens)' do
      with_tmpdir do |tmpdir|
        api_key_file = File.join(tmpdir, 'api_client.rb')
        hex_key_file = File.join(tmpdir, 'payment.rb')
        token_file = File.join(tmpdir, 'auth.rb')

        File.write(api_key_file, 'API_KEY = "d8F9ax83Lq4b72MzA1p9V0kLmNoPqRsT"')
        File.write(hex_key_file, 'SIGNING_SECRET = "c3ab8ff13720e8ad9047dd39466b3c89"')
        File.write(token_file, 'AUTH_TOKEN = "7xKp9mQw2vL8nR4tY1zB3cF6hJ0sD5gA"')

        entries = ['api_client.rb', 'payment.rb', 'auth.rb']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics.size).to eq(3)
        expect(diagnostics.map(&:code)).to all(eq('VLT-BUILD-SECRET-WARN'))
        expect(diagnostics.map(&:severity)).to all(eq(:warning))
        reasons = diagnostics.map { |d| d.evidence['reason'] }
        expect(reasons).to all(eq('high entropy string detected'))
      end
    end

    it 'does not raise warnings for normal code, URLs, UUIDs, or repetitive text' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'app.rb'), <<~RUBY)
          class ApplicationController
            def call(event, context)
              # Reference: https://docs.aws.amazon.com/lambda/latest/dg/welcome.html
              uuid = "123e4567-e89b-12d3-a456-426614174000"
              padding = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
              very_long_identifier_name_for_validation = true
              { status: 200, body: "ok" }
            end
          end
        RUBY
        File.write(File.join(tmpdir, 'README.md'), '# Documentation for Veltrunode Application')

        entries = ['app.rb', 'README.md']

        diagnostics = described_class.scan(source_dir: tmpdir, entries: entries)

        expect(diagnostics).to be_empty
      end
    end

    it 'skips content scanning for files larger than 1MB' do
      with_tmpdir do |tmpdir|
        large_file = File.join(tmpdir, 'large_log.txt')
        content = "AKIAIOSFODNN7EXAMPLE
#{'a' * 1_100_000}"
        File.write(large_file, content)

        diagnostics = described_class.scan(source_dir: tmpdir, entries: ['large_log.txt'])

        expect(diagnostics).to be_empty
      end
    end

    it 'handles binary files and invalid encodings gracefully' do
      with_tmpdir do |tmpdir|
        binary_file = File.join(tmpdir, 'data.bin')
        File.binwrite(binary_file, 'ÿþýüûú')

        diagnostics = described_class.scan(source_dir: tmpdir, entries: ['data.bin'])

        expect(diagnostics).to be_empty
      end
    end
  end
end
