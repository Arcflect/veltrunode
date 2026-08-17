# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'zip'
require_relative 'archive_result'
require_relative '../validation'

module Veltrunode
  module Build
    class DeterministicArchiver
      DEFAULT_FIXED_TIME = Time.utc(2024, 1, 1, 0, 0, 0)
      DEFAULT_INCLUDES = ['**/*'].freeze
      DEFAULT_EXCLUDES = ['.git/*', 'tmp/*', '*.tmp', '.DS_Store', '.veltrunode/*'].freeze

      class << self
        def archive(source_dir:, output_path:, includes: nil, excludes: nil, fixed_time: DEFAULT_FIXED_TIME)
          new(
            source_dir: source_dir,
            output_path: output_path,
            includes: includes,
            excludes: excludes,
            fixed_time: fixed_time
          ).archive
        end
      end

      def initialize(source_dir:, output_path:, includes: nil, excludes: nil, fixed_time: DEFAULT_FIXED_TIME)
        @source_dir = File.expand_path(source_dir.to_s)
        @output_path = File.expand_path(output_path.to_s)
        @includes = includes ? Array(includes).map(&:to_s) : DEFAULT_INCLUDES
        @excludes = excludes ? Array(excludes).map(&:to_s) : DEFAULT_EXCLUDES
        @fixed_time = fixed_time || DEFAULT_FIXED_TIME
      end

      def archive
        raise ValidationError, "Source directory does not exist: #{@source_dir}" unless File.directory?(@source_dir)

        entries = collect_and_filter_entries
        sorted_entries = entries.sort

        FileUtils.mkdir_p(File.dirname(@output_path))
        temp_output = "#{@output_path}.tmp.#{Process.pid}"

        write_zip_archive(temp_output, sorted_entries)
        FileUtils.mv(temp_output, @output_path)

        sha256 = Digest::SHA256.file(@output_path).hexdigest
        bytesize = File.size(@output_path)

        ArchiveResult.new(
          output_path: @output_path,
          sha256: sha256,
          entries: sorted_entries,
          bytesize: bytesize
        )
      ensure
        FileUtils.rm_f(temp_output) if temp_output && File.exist?(temp_output)
      end

      private

      def collect_and_filter_entries
        target_entries = []
        Dir.glob('**/*', File::FNM_DOTMATCH, base: @source_dir).each do |rel_path|
          next if %w[. ..].include?(rel_path)
          next if excluded?(rel_path)
          next unless included?(rel_path)

          target_entries << rel_path
        end
        target_entries
      end

      def excluded?(rel_path)
        @excludes.any? do |pat|
          clean_pat = pat.sub(%r{/\*\*$}, '').sub(%r{/\*$}, '')
          File.fnmatch?(pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?(pat, File.basename(rel_path), File::FNM_DOTMATCH) ||
            File.fnmatch?(clean_pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            rel_path.start_with?("#{clean_pat}/")
        end
      end

      def included?(rel_path)
        return true if @includes.empty? || @includes.include?('**/*')

        @includes.any? do |pat|
          clean_pat = pat.sub(%r{/\*\*$}, '').sub(%r{/\*$}, '')
          File.fnmatch?(pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            File.fnmatch?(pat, File.basename(rel_path), File::FNM_DOTMATCH) ||
            File.fnmatch?(clean_pat, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
            rel_path.start_with?("#{clean_pat}/")
        end
      end

      def to_dos_time(time)
        t = time.utc
        Zip::DOSTime.local(t.year, t.month, t.day, t.hour, t.min, t.sec)
      end

      def executable_file?(abs_path)
        return false unless File.file?(abs_path)

        mode = File.stat(abs_path).mode
        mode.anybits?(0o111)
      end

      def write_zip_archive(file_path, sorted_entries)
        dos_time = to_dos_time(@fixed_time)

        Zip::OutputStream.open(file_path) do |zip|
          sorted_entries.each do |rel_path|
            abs_path = File.join(@source_dir, rel_path)
            is_dir = File.directory?(abs_path)
            entry_name = is_dir && !rel_path.end_with?('/') ? "#{rel_path}/" : rel_path

            entry = Zip::Entry.new(
              file_path,
              entry_name,
              nil,
              nil,
              0,
              0,
              is_dir ? Zip::Entry::STORED : Zip::Entry::DEFLATED,
              0,
              dos_time
            )

            entry.unix_perms = is_dir || executable_file?(abs_path) ? 0o755 : 0o644

            zip.put_next_entry(entry)
            next if is_dir

            File.open(abs_path, 'rb') do |f|
              IO.copy_stream(f, zip)
            end
          end
        end
      end
    end
  end
end
