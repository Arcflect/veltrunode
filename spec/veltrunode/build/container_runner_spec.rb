# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Build::ContainerRunner do
  describe '.detect_executable' do
    it 'returns docker if docker is in PATH' do
      allow(described_class).to receive(:executable_in_path?).with('docker').and_return(true)
      allow(described_class).to receive(:executable_in_path?).with('podman').and_return(true)

      expect(described_class.detect_executable).to eq('docker')
    end

    it 'returns podman if docker is not in PATH but podman is' do
      allow(described_class).to receive(:executable_in_path?).with('docker').and_return(false)
      allow(described_class).to receive(:executable_in_path?).with('podman').and_return(true)

      expect(described_class.detect_executable).to eq('podman')
    end

    it 'returns nil if neither docker nor podman is in PATH' do
      allow(described_class).to receive(:executable_in_path?).with('docker').and_return(false)
      allow(described_class).to receive(:executable_in_path?).with('podman').and_return(false)

      expect(described_class.detect_executable).to be_nil
    end
  end

  describe '.validate_runtime_available!' do
    it 'raises ValidationError with VLT-BUILD-DOCKER-NOT-FOUND code when no container runtime is installed' do
      allow(described_class).to receive(:detect_executable).and_return(nil)

      expect do
        described_class.validate_runtime_available!
      end.to raise_error(Veltrunode::ValidationError) { |error|
        expect(error.message).to match(/Container runtime .* not found in PATH/)
        expect(error.diagnostics).not_to be_empty
        expect(error.diagnostics.first.code).to eq('VLT-BUILD-DOCKER-NOT-FOUND')
      }
    end
  end

  describe '#build_cli_command' do
    let(:runner) do
      described_class.new(
        image: 'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:1234567890abcdef',
        command: ['sh', '-c', 'bundle install'],
        environment: { 'BUNDLE_SILENCE_ROOT_WARNING' => '1' },
        volume_mounts: { '/tmp/source' => '/var/task' },
        architecture: 'arm64',
        workdir: '/var/task',
        runner_executable: 'docker'
      )
    end

    it 'constructs the correct docker run command with platform linux/arm64 and workdir' do
      cli_cmd = runner.build_cli_command
      expect(cli_cmd).to eq([
                              'docker', 'run', '--rm',
                              '--platform', 'linux/arm64',
                              '-w', '/var/task',
                              '-e', 'BUNDLE_SILENCE_ROOT_WARNING=1',
                              '-v', '/tmp/source:/var/task',
                              'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:1234567890abcdef',
                              'sh', '-c', 'bundle install'
                            ])
    end
  end

  describe '#run' do
    let(:runner) do
      described_class.new(
        image: 'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:1234567890abcdef',
        command: ['sh', '-c', 'bundle install'],
        architecture: 'x86_64',
        runner_executable: 'podman'
      )
    end

    it 'executes the container CLI via Open3.capture3 and returns output details' do
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      expect(Open3).to receive(:capture3).with(
        'podman', 'run', '--rm', '--platform', 'linux/amd64',
        'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:1234567890abcdef',
        'sh', '-c', 'bundle install'
      ).and_return(['Success output', '', status])

      result = runner.run
      expect(result[:executable]).to eq('podman')
      expect(result[:status]).to eq(0)
      expect(result[:stdout]).to eq('Success output')
    end

    it 'raises ValidationError when container execution fails' do
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      expect(Open3).to receive(:capture3).and_return(['', 'Build error in container', status])

      expect do
        runner.run
      end.to raise_error(Veltrunode::ValidationError) { |error|
        expect(error.message).to match(/Native container build failed using podman: exit code 1/)
        expect(error.diagnostics.first.code).to eq('VLT-BUILD-001')
      }
    end
  end
end
