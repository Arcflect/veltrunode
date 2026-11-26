# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/build/python_uv_layer_builder'
require 'veltrunode/build/archive_result'
require 'veltrunode/model/layer'

RSpec.describe Veltrunode::Build::PythonUvLayerBuilder do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-uv-layer-spec-') }
  let(:output_dir) { File.join(tmpdir, 'build', 'artifacts', 'layers') }
  let(:mock_archiver) do
    Class.new do
      class << self
        attr_accessor :last_staged_files, :last_wheel_metadata

        def archive(source_dir:, output_path:, includes: nil, excludes: nil) # rubocop:disable Lint/UnusedMethodArgument
          FileUtils.mkdir_p(File.dirname(output_path))
          @last_staged_files = Dir.glob('**/*', base: source_dir).select do |rel|
            File.file?(File.join(source_dir, rel))
          end.sort
          wheel_files = @last_staged_files.select { |f| f.end_with?('.dist-info/WHEEL') }
          @last_wheel_metadata = wheel_files.to_h do |rel|
            [rel, File.read(File.join(source_dir, rel))]
          end
          payload = @last_staged_files.join("\n")
          File.binwrite(output_path, payload)
          sha = Digest::SHA256.hexdigest(payload)
          Veltrunode::Build::ArchiveResult.new(
            output_path: output_path,
            sha256: sha,
            entries: @last_staged_files,
            bytesize: payload.bytesize
          )
        end
      end
    end
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe 'uv dependency resolution, binary wheel download, and python/lib/python3.x/site-packages layout' do
    before do
      File.write(File.join(tmpdir, 'pyproject.toml'), <<~TOML)
        [project]
        name = "ml-service"
        version = "0.1.0"
        requires-python = ">=3.12"
        dependencies = [
          "fastapi>=0.110.0",
          "pydantic-core==2.18.0"
        ]

        [project.optional-dependencies]
        aws = ["boto3>=1.34.0"]
      TOML
      File.write(File.join(tmpdir, 'uv.lock'), "version = 1\n")
    end

    it 'invokes uv pip install with Linux arm64 binary wheels and generates python/lib/python3.12/site-packages ZIP' do
      layer = Veltrunode::Model::Layer.new(
        name: 'py_uv_deps',
        compatible_runtimes: ['python3.12'],
        architecture: :arm64,
        build_environment: {
          'package_manager' => 'uv',
          'pyproject' => 'pyproject.toml',
          'lockfile' => 'uv.lock',
          'extras' => ['aws'],
          'only_binary' => true
        }
      )

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['Resolved 3 packages in 12ms', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        layer: layer,
        source_dir: tmpdir,
        output_dir: output_dir,
        runner_executable: 'uv',
        command_runner: runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(executed_commands.size).to eq(1)
      cmd = executed_commands.first
      expect(cmd).to include(
        'uv', 'pip', 'install',
        '--requirement', File.join(tmpdir, 'pyproject.toml'),
        '--python-platform', 'aarch64-unknown-linux-gnu',
        '--python-version', '3.12',
        '--only-binary', ':all:',
        '--no-cache',
        '--extra', 'aws'
      )

      expect(result.layer_name).to eq('py_uv_deps')
      expect(result.entries).to include(
        'python/lib/python3.12/site-packages/fastapi/__init__.py',
        'python/lib/python3.12/site-packages/pydantic_core/__init__.py',
        'python/lib/python3.12/site-packages/boto3/__init__.py'
      )
      wheel_meta = mock_archiver.last_wheel_metadata[
        'python/lib/python3.12/site-packages/pydantic_core-0.1.0.dist-info/WHEEL'
      ]
      expect(wheel_meta).to include('Tag: cp312-cp312-manylinux2014_aarch64')
    end

    it 'fetches Linux x86_64 binary wheels (--python-platform x86_64-unknown-linux-gnu) when architecture is x86_64' do
      File.write(File.join(tmpdir, 'requirements.txt'), "numpy==1.26.4\norjson>=3.10.0\n")

      layer = Veltrunode::Model::Layer.new(
        name: 'py_x86_deps',
        compatible_runtimes: ['python3.11'],
        architecture: :x86_64,
        build_environment: {
          'package_manager' => 'uv',
          'requirements' => 'requirements.txt'
        }
      )

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        layer: layer,
        source_dir: tmpdir,
        output_dir: output_dir,
        pyproject_path: File.join(tmpdir, 'non_existent_pyproject.toml'),
        runner_executable: 'uv',
        command_runner: runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(executed_commands.first).to include(
        '--python-platform', 'x86_64-unknown-linux-gnu',
        '--python-version', '3.11',
        '--only-binary', ':all:'
      )
      expect(result.entries).to include(
        'python/lib/python3.11/site-packages/numpy/__init__.py',
        'python/lib/python3.11/site-packages/orjson/__init__.py'
      )
      wheel_meta = mock_archiver.last_wheel_metadata[
        'python/lib/python3.11/site-packages/orjson-0.1.0.dist-info/WHEEL'
      ]
      expect(wheel_meta).to include('Tag: cp311-cp311-manylinux2014_x86_64')
    end

    it 'parses Poetry [tool.poetry.dependencies] from pyproject.toml' do
      poetry_toml = <<~TOML
        [tool.poetry]
        name = "poetry-lambda"
        version = "0.1.0"

        [tool.poetry.dependencies]
        python = "^3.12"
        httpx = "^0.27.0"
        cryptography = { version = "^42.0.0" }
      TOML

      deps = described_class.parse_pyproject_dependencies(poetry_toml)
      expect(deps).to eq(%w[httpx cryptography])
    end

    it 'raises ValidationError with VLT-BUILD-PYTHON-MANIFEST-NOT-FOUND when manifest is missing' do
      FileUtils.rm_f(File.join(tmpdir, 'pyproject.toml'))
      layer = Veltrunode::Model::Layer.new(
        name: 'missing_manifest_layer',
        compatible_runtimes: ['python3.12'],
        build_environment: { 'package_manager' => 'uv' }
      )

      expect do
        described_class.build(
          layer: layer,
          source_dir: tmpdir,
          output_dir: output_dir,
          archiver: mock_archiver,
          execute_build: false
        )
      end.to(raise_error(Veltrunode::ValidationError) do |err|
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-PYTHON-MANIFEST-NOT-FOUND')
      end)
    end
  end
end
