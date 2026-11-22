# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/build/image_builder'
require 'veltrunode/build/function_packager'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Build::ImageBuilder do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-image-builder-spec-') }
  let(:dockerfile_path) { File.join(tmpdir, 'Dockerfile') }

  before do
    File.write(dockerfile_path, <<~DOCKERFILE)
      FROM public.ecr.aws/lambda/python:3.12
      COPY app.py ${LAMBDA_TASK_ROOT}
      CMD ["app.handler"]
    DOCKERFILE
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe '.build' do
    it 'builds a Docker image with the expected CLI arguments and returns a PackageResult' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ml_inference',
        image: {
          dockerfile: './Dockerfile',
          tag: 'v1.2.0',
          target: 'runtime',
          build_args: { 'MODEL_VERSION' => '2026.11' }
        },
        architecture: :arm64
      )

      executed_commands = []
      runner = lambda do |cmd|
        executed_commands << cmd
        ['Successfully built image', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        runner_executable: 'docker',
        command_runner: runner
      )

      expect(result).to be_a(Veltrunode::Build::PackageResult)
      expect(result.image?).to be(true)
      expect(result.package_type).to eq('Image')
      expect(result.function_name).to eq('ml_inference')
      expect(result.image_uri).to eq('ml_inference:v1.2.0')
      expect(result.image_tag).to eq('v1.2.0')
      expect(result.dockerfile_path).to eq(dockerfile_path)
      expect(result.content_hash).to match(/\A[0-9a-f]{64}\z/)

      expect(executed_commands.size).to eq(1)
      expect(executed_commands.first).to eq(
        [
          'docker', 'build',
          '--platform', 'linux/arm64',
          '-f', dockerfile_path,
          '-t', 'ml_inference:v1.2.0',
          '--target', 'runtime',
          '--build-arg', 'MODEL_VERSION=2026.11',
          tmpdir
        ]
      )
    end

    it 'raises ValidationError with VLT-BUILD-DOCKERFILE-NOT-FOUND when Dockerfile is missing' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ml_inference',
        image: { dockerfile: './Missing.Dockerfile', tag: 'v1.0.0' }
      )

      expect do
        described_class.build(
          function: fn,
          source_dir: tmpdir,
          runner_executable: 'docker',
          execute_build: false
        )
      end.to(raise_error(Veltrunode::ValidationError) do |err|
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-DOCKERFILE-NOT-FOUND')
      end)
    end

    it 'raises ValidationError with VLT-BUILD-IMAGE-001 when docker build fails' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ml_inference',
        image: { dockerfile: './Dockerfile', tag: 'v1.0.0' }
      )

      runner = lambda do |_cmd|
        ['', 'ERROR: failed to solve', instance_double(Process::Status, success?: false, exitstatus: 1)]
      end

      expect do
        described_class.build(
          function: fn,
          source_dir: tmpdir,
          runner_executable: 'docker',
          command_runner: runner
        )
      end.to(raise_error(Veltrunode::ValidationError) do |err|
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-IMAGE-001')
      end)
    end

    it 'delegates from FunctionPackager.package when function.image? is true' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ml_inference',
        image: { dockerfile: './Dockerfile', tag: 'v1.2.0' }
      )

      result = Veltrunode::Build::FunctionPackager.package(
        function: fn,
        source_dir: tmpdir
      )

      expect(result.image?).to be(true)
      expect(result.package_type).to eq('Image')
      expect(result.image_uri).to eq('ml_inference:v1.2.0')
      expect(result.image_tag).to eq('v1.2.0')
    end
  end
end
