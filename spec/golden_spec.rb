# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

module GoldenSpecHelper
  FIXTURES_BASE_DIR = File.expand_path('fixtures/golden', __dir__)
  extend RSpec::Matchers

  class << self
    def updated_fixtures
      @updated_fixtures ||= []
    end

    def record_update(path)
      return unless path.start_with?(FIXTURES_BASE_DIR)

      updated_fixtures << path
    end

    def update_golden?
      %w[1 true].include?(ENV['UPDATE_GOLDEN'].to_s.downcase)
    end

    def report_updates(out: $stdout, fixtures: updated_fixtures)
      return if fixtures.empty?

      out.puts "\n"
      out.puts '=' * 80
      out.puts '  [GOLDEN TEST] Fixtures have been updated!'
      out.puts '  Updated files:'
      fixtures.each do |file|
        out.puts "    - #{file}"
      end
      out.puts '  Please review the semantic changes carefully before committing:'
      out.puts '    git diff spec/fixtures/golden/'
      out.puts '=' * 80
      out.puts "\n"
    end

    def verify_fixture(actual_content, fixture_path)
      if update_golden?
        if !File.exist?(fixture_path) || File.read(fixture_path) != actual_content
          File.write(fixture_path, actual_content)
          record_update(fixture_path)
        end
      else
        expect(File.exist?(fixture_path)).to be(true),
                                             "Missing golden fixture: #{fixture_path}. " \
                                             'Run UPDATE_GOLDEN=1 bundle exec rspec to generate it.'

        expected_content = File.read(fixture_path)
        expect(actual_content).to eq(expected_content)
      end
    end
  end
end

RSpec.configure do |config|
  config.after(:suite) do
    GoldenSpecHelper.report_updates
  end
end

RSpec.describe 'Golden Tests' do
  fixed_time = Time.utc(2026, 1, 1, 0, 0, 0)
  fixture_dirs = Dir.glob(File.join(GoldenSpecHelper::FIXTURES_BASE_DIR, '*')).select { |f| File.directory?(f) }.sort

  fixture_dirs.each do |fixture_dir|
    pattern_name = File.basename(fixture_dir)

    describe "Pattern '#{pattern_name}'" do
      let(:veltrunodefile_path) { File.join(fixture_dir, 'Veltrunodefile') }
      let(:template_path) { File.join(fixture_dir, 'template.yml') }
      let(:manifest_path) { File.join(fixture_dir, 'manifest.json') }

      it 'compiles to the expected CloudFormation template.yml and manifest.json' do
        expect(File.exist?(veltrunodefile_path)).to be(true), "Missing Veltrunodefile in #{fixture_dir}"

        content = File.read(veltrunodefile_path)
        app = Veltrunode.parse(content, veltrunodefile_path)

        diagnostics = Veltrunode::Validation::Engine.run(app)
        errors = diagnostics.select { |d| d.severity == :error }
        expect(errors).to be_empty, "Validation failed for #{pattern_name}: #{errors.map(&:summary).join('; ')}"

        actual_template = Veltrunode::Compiler::CloudFormation.to_yaml(app)
        actual_manifest = Veltrunode::Compiler::Manifest.to_json(application: app, built_at: fixed_time)

        GoldenSpecHelper.verify_fixture(actual_template, template_path)
        GoldenSpecHelper.verify_fixture(actual_manifest, manifest_path)
      end
    end
  end

  describe 'Golden Test Framework' do
    around do |example|
      orig_env = ENV.fetch('UPDATE_GOLDEN', nil)
      orig_fixtures = GoldenSpecHelper.updated_fixtures.dup
      example.run
    ensure
      if orig_env.nil?
        ENV.delete('UPDATE_GOLDEN')
      else
        ENV['UPDATE_GOLDEN'] = orig_env
      end
      GoldenSpecHelper.updated_fixtures.replace(orig_fixtures)
    end

    describe 'GoldenSpecHelper' do
      describe '.update_golden?' do
        it 'returns true for truthy environment variable values' do
          %w[1 true TRUE True].each do |val|
            ENV['UPDATE_GOLDEN'] = val
            expect(GoldenSpecHelper.update_golden?).to be(true)
          end
        end

        it 'returns false for falsy or missing environment variable values' do
          [nil, '', '0', 'false', 'FALSE', 'no'].each do |val|
            if val.nil?
              ENV.delete('UPDATE_GOLDEN')
            else
              ENV['UPDATE_GOLDEN'] = val
            end
            expect(GoldenSpecHelper.update_golden?).to be(false)
          end
        end
      end

      describe '.record_update' do
        it 'records paths within FIXTURES_BASE_DIR' do
          valid_path = File.join(GoldenSpecHelper::FIXTURES_BASE_DIR, 'dummy', 'template.yml')
          GoldenSpecHelper.record_update(valid_path)
          expect(GoldenSpecHelper.updated_fixtures).to include(valid_path)
        end

        it 'ignores paths outside FIXTURES_BASE_DIR' do
          invalid_path = '/tmp/dummy/template.yml'
          GoldenSpecHelper.record_update(invalid_path)
          expect(GoldenSpecHelper.updated_fixtures).not_to include(invalid_path)
        end
      end

      describe '.report_updates' do
        it 'prints updated fixtures report to output stream' do
          buffer = StringIO.new
          dummy_file = File.join(GoldenSpecHelper::FIXTURES_BASE_DIR, 'my_test', 'template.yml')
          GoldenSpecHelper.report_updates(out: buffer, fixtures: [dummy_file])

          output = buffer.string
          expect(output).to include('[GOLDEN TEST] Fixtures have been updated!')
          expect(output).to include(dummy_file)
          expect(output).to include('git diff spec/fixtures/golden/')
        end

        it 'does not print anything when fixtures list is empty' do
          buffer = StringIO.new
          GoldenSpecHelper.report_updates(out: buffer, fixtures: [])
          expect(buffer.string).to be_empty
        end
      end

      describe '.verify_fixture' do
        it 'detects discrepancy between generated output and fixture when UPDATE_GOLDEN is disabled' do
          Dir.mktmpdir do |tmpdir|
            tpl_file = File.join(tmpdir, 'template.yml')
            File.write(tpl_file, 'expected golden content')

            ENV.delete('UPDATE_GOLDEN')
            expect do
              GoldenSpecHelper.verify_fixture('different generated content', tpl_file)
            end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
          end
        end

        it 'raises error when fixture file does not exist and UPDATE_GOLDEN is disabled' do
          missing_file = File.join(Dir.tmpdir, 'missing_golden_file.yml')
          FileUtils.rm_f(missing_file)

          ENV.delete('UPDATE_GOLDEN')
          expect do
            GoldenSpecHelper.verify_fixture('some content', missing_file)
          end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /Missing golden fixture/)
        end

        it 'passes when generated output matches fixture and UPDATE_GOLDEN is disabled' do
          Dir.mktmpdir do |tmpdir|
            tpl_file = File.join(tmpdir, 'template.yml')
            File.write(tpl_file, 'matching content')

            ENV.delete('UPDATE_GOLDEN')
            expect do
              GoldenSpecHelper.verify_fixture('matching content', tpl_file)
            end.not_to raise_error
          end
        end

        it 'updates fixture file and records update when UPDATE_GOLDEN is enabled' do
          dummy_fixture_dir = File.join(GoldenSpecHelper::FIXTURES_BASE_DIR, '.tmp_test_fixture')
          FileUtils.mkdir_p(dummy_fixture_dir)
          tpl_file = File.join(dummy_fixture_dir, 'template.yml')
          File.write(tpl_file, 'old content')

          begin
            ENV['UPDATE_GOLDEN'] = '1'
            new_content = 'new template content'

            GoldenSpecHelper.verify_fixture(new_content, tpl_file)

            expect(File.read(tpl_file)).to eq(new_content)
            expect(GoldenSpecHelper.updated_fixtures).to include(tpl_file)
          ensure
            FileUtils.rm_rf(dummy_fixture_dir)
          end
        end
      end
    end
  end
end
