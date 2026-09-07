# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Build
    class SecretScanner
      SECRET_FILENAME_PATTERNS = %w[
        .env .env.* *.pem *.key id_rsa id_dsa id_ed25519 credentials
        credentials.json *.secret secrets.yml secrets.json *.p12 *.pfx
      ].freeze

      SECRET_CONTENT_PATTERNS = [
        /-----BEGIN (?:RSA|DSA|EC|OPENSSH)?\s*(?:PRIVATE )?KEY-----/,
        %r{AWS_SECRET_ACCESS_KEY\s*=\s*['"]?[A-Za-z0-9/+=]{40}['"]?},
        /AKIA[0-9A-Z]{16}/
      ].freeze

      UUID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

      class << self
        def scan(source_dir:, entries:)
          new(source_dir: source_dir, entries: entries).scan
        end

        def calculate_shannon_entropy(str)
          return 0.0 if str.nil? || str.empty?

          len = str.length.to_f
          counts = str.each_char.tally
          counts.values.sum do |count|
            p = count / len
            -p * Math.log2(p)
          end
        end
      end

      def initialize(source_dir:, entries:)
        @source_dir = source_dir.to_s
        @entries = Array(entries).map(&:to_s)
      end

      def scan
        diagnostics = []

        @entries.each do |rel_path|
          abs_path = File.join(@source_dir, rel_path)
          next unless File.file?(abs_path)

          reason = scan_file(rel_path, abs_path)
          next unless reason

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-SECRET-WARN',
            severity: :warning,
            summary: "Possible secret file detected: #{rel_path} (#{reason}).",
            suggested_action: 'Remove sensitive files from source directory or exclude them from packaging.',
            evidence: { 'file' => rel_path, 'reason' => reason }
          )
        end

        diagnostics
      end

      private

      def scan_file(rel_path, abs_path)
        filename = File.basename(rel_path)

        SECRET_FILENAME_PATTERNS.each do |pat|
          return 'sensitive file pattern' if File.fnmatch?(pat, filename, File::FNM_DOTMATCH | File::FNM_CASEFOLD)
        end

        return nil if File.size(abs_path) > 1_048_576 # Skip content scan for files > 1MB

        begin
          content = File.read(abs_path)
          SECRET_CONTENT_PATTERNS.each do |pattern|
            return 'sensitive content detected' if pattern.match?(content)
          end

          return 'high entropy string detected' if detect_high_entropy_string(content)
        rescue StandardError
          # Ignore read/encoding errors for binary files
        end

        nil
      end

      def detect_high_entropy_string(content)
        tokens = content.scan(%r{[A-Za-z0-9_\-+/=]{20,}})
        tokens.any? do |token|
          next false if token.chars.uniq.size < 10
          next false if UUID_PATTERN.match?(token)

          if token.match?(/\A[0-9a-fA-F]{32,}\z/)
            token.chars.uniq.size >= 12 && self.class.calculate_shannon_entropy(token) >= 3.5
          elsif token.match?(%r{\A[A-Za-z0-9_\-+/=]{20,}\z})
            self.class.calculate_shannon_entropy(token) >= 4.2
          else
            false
          end
        end
      end
    end
  end
end
