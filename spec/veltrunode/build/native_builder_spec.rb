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

    it 'uses correct image for arm64 architecture' do
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
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          container_runner: mock_container_runner
        )

        expect(result[:image]).to include('arm64')
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
  end
end
