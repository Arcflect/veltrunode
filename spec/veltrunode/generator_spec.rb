# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/generator'
require 'veltrunode/settings_loader'
require 'veltrunode/validation/engine'

RSpec.describe Veltrunode::Generator do
  describe '.run' do
    it 'generates a complete skeleton project with Ruby runtime by default' do
      Dir.mktmpdir('veltrunode-init-') do |tmp_dir|
        result = described_class.run(tmp_dir)

        expect(result.created_files).to contain_exactly(
          'Veltrunodefile',
          'Gemfile',
          '.gitignore',
          '.github/workflows/ci.yml',
          'functions/app.rb',
          'spec/spec_helper.rb',
          'spec/functions/app_spec.rb'
        )
        expect(result.skipped_files).to be_empty

        # Check file existence
        expect(File.exist?(File.join(tmp_dir, 'Veltrunodefile'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, 'Gemfile'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, '.gitignore'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, '.github/workflows/ci.yml'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, 'functions/app.rb'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, 'spec/spec_helper.rb'))).to be(true)
        expect(File.exist?(File.join(tmp_dir, 'spec/functions/app_spec.rb'))).to be(true)

        # Content verification
        veltrunodefile_content = File.read(File.join(tmp_dir, 'Veltrunodefile'))
        expect(veltrunodefile_content).to include('Veltrunode.application')
        expect(veltrunodefile_content).to include("runtime ruby: '3.3'")
        expect(veltrunodefile_content).to include("handler 'functions/app.handler'")

        # Verify that generated project passes validation
        app = Veltrunode::SettingsLoader.load(file_path: File.join(tmp_dir, 'Veltrunodefile'))
        diagnostics = Veltrunode::Validation::Engine.run(app, source_dir: tmp_dir)
        errors = diagnostics.select { |d| d.severity == :error }

        expect(errors).to be_empty
      end
    end

    it 'generates a skeleton project with Python runtime when specified' do
      Dir.mktmpdir('veltrunode-init-py-') do |tmp_dir|
        result = described_class.run(tmp_dir, runtime: 'python3.12')

        expect(result.created_files).to include('functions/app.py')
        expect(File.exist?(File.join(tmp_dir, 'functions/app.py'))).to be(true)

        veltrunodefile_content = File.read(File.join(tmp_dir, 'Veltrunodefile'))
        expect(veltrunodefile_content).to include("runtime 'python3.12'")

        # Verify validation passes
        app = Veltrunode::SettingsLoader.load(file_path: File.join(tmp_dir, 'Veltrunodefile'))
        diagnostics = Veltrunode::Validation::Engine.run(app, source_dir: tmp_dir)
        errors = diagnostics.select { |d| d.severity == :error }

        expect(errors).to be_empty
      end
    end

    it 'generates a skeleton project with Node.js runtime when specified' do
      Dir.mktmpdir('veltrunode-init-node-') do |tmp_dir|
        result = described_class.run(tmp_dir, runtime: 'nodejs20.x')

        expect(result.created_files).to include('functions/app.js')
        expect(File.exist?(File.join(tmp_dir, 'functions/app.js'))).to be(true)

        veltrunodefile_content = File.read(File.join(tmp_dir, 'Veltrunodefile'))
        expect(veltrunodefile_content).to include("runtime 'nodejs20.x'")

        # Verify validation passes
        app = Veltrunode::SettingsLoader.load(file_path: File.join(tmp_dir, 'Veltrunodefile'))
        diagnostics = Veltrunode::Validation::Engine.run(app, source_dir: tmp_dir)
        errors = diagnostics.select { |d| d.severity == :error }

        expect(errors).to be_empty
      end
    end

    it 'skips existing files without overwriting them' do
      Dir.mktmpdir('veltrunode-init-skip-') do |tmp_dir|
        # Pre-create Veltrunodefile with custom content
        existing_veltrunodefile = File.join(tmp_dir, 'Veltrunodefile')
        File.write(existing_veltrunodefile, '# Custom existing file')

        result = described_class.run(tmp_dir)

        expect(result.skipped_files).to include('Veltrunodefile')
        expect(result.created_files).not_to include('Veltrunodefile')
        expect(File.read(existing_veltrunodefile)).to eq('# Custom existing file')
      end
    end

    it 'normalizes custom app_name with invalid characters' do
      Dir.mktmpdir('veltrunode-init-app-') do |tmp_dir|
        result = described_class.run(tmp_dir, app_name: 'my invalid@app name!')
        expect(result.created_files).to include('Veltrunodefile')

        content = File.read(File.join(tmp_dir, 'Veltrunodefile'))
        expect(content).to include("Veltrunode.application 'my_invalid_app_name_'")
      end
    end

    it 'sanitizes invalid or unsafe runtime strings and falls back to default runtime' do
      Dir.mktmpdir('veltrunode-init-safe-') do |tmp_dir|
        result = described_class.run(tmp_dir, runtime: "ruby'\n# injected content")

        expect(result.created_files).to include('Veltrunodefile', 'functions/app.rb')
        content = File.read(File.join(tmp_dir, 'Veltrunodefile'))
        expect(content).not_to include('# injected content')
        expect(content).to include("runtime ruby: '3.3'")
      end
    end
  end
end
