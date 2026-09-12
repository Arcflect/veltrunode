# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

module GoldenSpecHelper
  FIXTURES_BASE_DIR = File.expand_path('fixtures/golden', __dir__)

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
  end
end

RSpec.configure do |config|
  config.after(:suite) do
    if GoldenSpecHelper.updated_fixtures.any?
      puts "\n"
      puts '=' * 80
      puts '  [GOLDEN TEST] Fixtures have been updated!'
      puts '  Updated files:'
      GoldenSpecHelper.updated_fixtures.each do |file|
        puts "    - #{file}"
      end
      puts '  Please review the semantic changes carefully before committing:'
      puts '    git diff spec/fixtures/golden/'
      puts '=' * 80
      puts "\n"
    end
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

        if GoldenSpecHelper.update_golden?
          if !File.exist?(template_path) || File.read(template_path) != actual_template
            File.write(template_path, actual_template)
            GoldenSpecHelper.record_update(template_path)
          end

          if !File.exist?(manifest_path) || File.read(manifest_path) != actual_manifest
            File.write(manifest_path, actual_manifest)
            GoldenSpecHelper.record_update(manifest_path)
          end
        else
          expect(File.exist?(template_path)).to be(true),
                                                "Missing golden fixture: #{template_path}. " \
                                                'Run UPDATE_GOLDEN=1 bundle exec rspec to generate it.'
          expect(File.exist?(manifest_path)).to be(true),
                                                "Missing golden fixture: #{manifest_path}. " \
                                                'Run UPDATE_GOLDEN=1 bundle exec rspec to generate it.'

          expected_template = File.read(template_path)
          expected_manifest = File.read(manifest_path)

          expect(actual_template).to eq(expected_template)
          expect(actual_manifest).to eq(expected_manifest)
        end
      end
    end
  end

  describe 'Golden Test Framework' do
    it 'detects discrepancy between generated output and fixture when UPDATE_GOLDEN is disabled' do
      Dir.mktmpdir do |tmpdir|
        vlt_file = File.join(tmpdir, 'Veltrunodefile')
        tpl_file = File.join(tmpdir, 'template.yml')

        dsl = <<~RUBY
          Veltrunode.application 'discrepancy-app' do
            aws region: 'ap-northeast-1', account: '123456789012'
            runtime ruby: '3.3', architecture: :x86_64
            function :worker do
              handler 'app.handler'
            end
          end
        RUBY
        File.write(vlt_file, dsl)
        File.write(tpl_file, 'outdated template content')

        app = Veltrunode.parse(dsl, vlt_file)
        actual_template = Veltrunode::Compiler::CloudFormation.to_yaml(app)

        expect(actual_template).not_to eq(File.read(tpl_file))
      end
    end

    it 'updates fixture file and records update when UPDATE_GOLDEN is enabled' do
      test_helper = Class.new do
        attr_reader :updated_fixtures

        def initialize
          @updated_fixtures = []
        end

        def record_update(path)
          @updated_fixtures << path
        end

        def update_golden?
          true
        end
      end.new

      Dir.mktmpdir do |tmpdir|
        tpl_file = File.join(tmpdir, 'template.yml')
        File.write(tpl_file, 'old content')

        new_content = 'new template content'

        if test_helper.update_golden?
          File.write(tpl_file, new_content)
          test_helper.record_update(tpl_file)
        end

        expect(File.read(tpl_file)).to eq(new_content)
        expect(test_helper.updated_fixtures).to include(tpl_file)
      end
    end
  end
end
