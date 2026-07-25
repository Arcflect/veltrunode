# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Veltrunode::SettingsLoader do
  def with_tmpdir
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  it 'auto-detects Veltrunodefile in current directory' do
    with_tmpdir do
      File.write('Veltrunodefile', <<~RUBY)
        Veltrunode.application "demo-app" do
          aws region: "ap-northeast-1", account: "123456789012"
          runtime ruby: "3.4", architecture: :arm64
        end
      RUBY

      app = described_class.load

      expect(app).to be_a(Veltrunode::Application)
      expect(app.name).to eq('demo-app')
      expect(app.runtime).to eq('ruby3.4')
    end
  end

  it 'loads custom file path when --file style path is provided' do
    with_tmpdir do
      File.write('custom_config.rb', <<~RUBY)
        Veltrunode.application "custom-app" do
          runtime ruby: "3.4"
        end
      RUBY

      app = described_class.load(file_path: 'custom_config.rb')

      expect(app.name).to eq('custom-app')
    end
  end

  it 'raises VLT-DSL-004 when file does not exist' do
    with_tmpdir do
      expect do
        described_class.load(file_path: 'missing/Veltrunodefile')
      end.to raise_error(Veltrunode::SettingsLoader::LoadError, /VLT-DSL-004/)
    end
  end

  it 'raises VLT-DSL-002 with line number for syntax errors' do
    with_tmpdir do
      File.write('Veltrunodefile', <<~RUBY)
        Veltrunode.application "broken-app" do
          runtime ruby: "3.4"
      RUBY

      expect do
        described_class.load
      end.to raise_error(Veltrunode::SettingsLoader::LoadError, /VLT-DSL-002/)

      begin
        described_class.load
      rescue Veltrunode::SettingsLoader::LoadError => e
        expect(e.message).to match(/line \d+/)
      end
    end
  end

  it 'raises VLT-DSL-003 when Veltrunode.application is not defined' do
    with_tmpdir do
      File.write('Veltrunodefile', 'puts "no app"')
      expect do
        described_class.load
      end.to raise_error(Veltrunode::SettingsLoader::LoadError, /VLT-DSL-003/)
    end
  end

  it 'raises VLT-DSL-003 when evaluation raises a runtime error' do
    with_tmpdir do
      File.write('Veltrunodefile', 'raise "boom"')
      expect do
        described_class.load
      end.to raise_error(Veltrunode::SettingsLoader::LoadError, /VLT-DSL-003/)
    end
  end
end
