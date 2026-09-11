# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Build::NativeBuilder do
  let(:mock_container_runner) { class_double(Veltrunode::Build::ContainerRunner) }

  describe '.build' do
    it 'pins build image with digest and delegates container execution' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/@sha256:/),
          architecture: 'x86_64'
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Build success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'bundle'),
          runtime: 'ruby3.3',
          architecture: 'x86_64',
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          container_runner: mock_container_runner
        )

        expect(result[:image_digest]).to match(/\Asha256:[a-f0-9]{64}\z/)
        expect(result[:image]).to include('@sha256:')
      end
    end

    it 'uses runtime-specific image for arm64 architecture when build_on is default' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/latest-arm64@sha256:/),
          architecture: 'arm64'
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Build success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'bundle'),
          runtime: 'ruby3.3',
          architecture: 'arm64',
          build_on: nil,
          container_runner: mock_container_runner
        )

        expect(result[:image]).to include('latest-arm64')
      end
    end

    it 'uses Amazon Linux 2023 image when build_on is :amazon_linux_2023' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/amazonlinux:2023@sha256:/),
          architecture: 'arm64'
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Build success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'bundle'),
          runtime: 'ruby3.3',
          architecture: 'arm64',
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          container_runner: mock_container_runner
        )

        expect(result[:image]).to include('amazonlinux:2023')
      end
    end

    it 'raises ValidationError when output_dir is not source_dir/vendor/bundle' do
      Dir.mktmpdir do |dir|
        expect do
          described_class.build(
            source_dir: dir,
            output_dir: File.join(dir, 'other_dir'),
            runtime: 'ruby3.3',
            architecture: 'x86_64',
            build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
            container_runner: mock_container_runner
          )
        end.to raise_error(Veltrunode::ValidationError, /output_dir must be/)
      end
    end

    it 'contains valid 64-character hex SHA-256 digests for all DEFAULT_IMAGE_DIGESTS' do
      described_class::DEFAULT_IMAGE_DIGESTS.each do |key, image|
        digest = image.split('@sha256:').last
        expect(digest).to match(/\A[a-f0-9]{64}\z/), "Expected #{key} digest to be 64 hex chars, got: #{digest.inspect}"
      end
    end
    it 'configures container command and output_dir for Python runtime' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/build-python3.12:latest-x86_64@sha256:/),
          architecture: 'x86_64',
          command: ['sh', '-c', 'cd /var/task && pip install -r requirements.txt -t vendor/python'],
          environment: hash_including('PIP_DISABLE_PIP_VERSION_CHECK' => '1')
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Pip success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'python'),
          runtime: 'python3.12',
          architecture: 'x86_64',
          build_on: nil,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'vendor', 'python'))
        expect(result[:image]).to include('build-python3.12:latest-x86_64')
      end
    end

    it 'raises ValidationError when output_dir for Python is not vendor/python' do
      Dir.mktmpdir do |dir|
        expect do
          described_class.build(
            source_dir: dir,
            output_dir: File.join(dir, 'vendor', 'bundle'),
            runtime: 'python3.12',
            architecture: 'x86_64',
            container_runner: mock_container_runner
          )
        end.to raise_error(Veltrunode::ValidationError, %r{vendor/python})
      end
    end

    it 'configures container command and output_dir for Node.js runtime' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/build-nodejs20.x:latest-arm64@sha256:/),
          architecture: 'arm64',
          command: ['sh', '-c', 'cd /var/task && npm install --production'],
          environment: hash_including('NODE_ENV' => 'production')
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          build_on: nil,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
        expect(result[:image]).to include('build-nodejs20.x:latest-arm64')
      end
    end

    it 'raises ValidationError when output_dir for Node.js is not node_modules' do
      Dir.mktmpdir do |dir|
        expect do
          described_class.build(
            source_dir: dir,
            output_dir: File.join(dir, 'vendor', 'node'),
            runtime: 'nodejs20.x',
            architecture: 'arm64',
            container_runner: mock_container_runner
          )
        end.to raise_error(Veltrunode::ValidationError, /node_modules/)
      end
    end
    it 'uses custom requirements_path for Python container command when specified' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task && pip install -r requirements-lambda.txt -t vendor/python']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Pip success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'python'),
          runtime: 'python3.12',
          architecture: 'x86_64',
          requirements_path: File.join(dir, 'requirements-lambda.txt'),
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'vendor', 'python'))
      end
    end

    it 'falls back to layer.build_environment requirements setting for Python container command' do
      layer = Veltrunode::Model::Layer.new(
        name: 'custom_py_layer',
        compatible_runtimes: ['python3.12'],
        build_environment: { 'requirements' => 'custom-requirements.txt' }
      )

      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task && pip install -r custom-requirements.txt -t vendor/python']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Pip success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'python'),
          runtime: 'python3.12',
          architecture: 'x86_64',
          layer: layer,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'vendor', 'python'))
      end
    end
  end
end
