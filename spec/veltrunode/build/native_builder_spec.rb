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
        expect(digest).not_to match(/\A(0123456789abcdef|123456789abcdef0|6789abcdef012345|abcdef0123456789)/)
      end
    end

    it 'resolves published SAM build image digests for Python and Node.js runtimes' do
      expect(described_class::DEFAULT_IMAGE_DIGESTS['python3.12-x86_64']).to include(
        '4f6d1c3b9b2ad0ca1618a519ef409e3c15a7da6b87e9d064e23843ce53a307b5'
      )
      expect(described_class::DEFAULT_IMAGE_DIGESTS['python3.12-arm64']).to include(
        '227044c26f87e9e536eebf515b65cf2e058107e74c903565ba5d1e9c45543ad1'
      )
      expect(described_class::DEFAULT_IMAGE_DIGESTS['nodejs20.x-x86_64']).to include(
        'eee793edc5cf0c5d6782fa3d83329c227c43bd66fdf0c8ba6a655c51c0b51ff2'
      )
      expect(described_class::DEFAULT_IMAGE_DIGESTS['nodejs20.x-arm64']).to include(
        '7a6183f6573b202fa2d542b34a97d45ea7aa5642ad80b765ee9390025d25c228'
      )
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

    it 'uses locked install (npm ci --production) for Node.js runtime when package-lock.json is present' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task && npm ci --production']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'package.json'), '{}')
        File.write(File.join(dir, 'package-lock.json'), '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
      end
    end

    it 'uses locked install (npm ci --production) and manages backup/restore when custom lockfile is present' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: [
            'sh', '-c',
            satisfy do |cmd|
              cmd.include?('cp package-prod.json package.json') &&
                cmd.include?('cp package-prod-lock.json package-lock.json') &&
                cmd.include?('npm ci --production') &&
                cmd.include?('.package-lock.json.veltrunode.bak')
            end
          ]
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        pkg_path = File.join(dir, 'package-prod.json')
        lock_path = File.join(dir, 'package-prod-lock.json')
        File.write(pkg_path, '{}')
        File.write(lock_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: pkg_path,
          package_lock_path: lock_path,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
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
    it 'uses custom package_json_path in subdirectory for Node.js container command' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task/frontend && npm install --production']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        frontend_dir = File.join(dir, 'frontend')
        FileUtils.mkdir_p(frontend_dir)
        pkg_path = File.join(frontend_dir, 'package.json')
        File.write(pkg_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(frontend_dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: pkg_path,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(frontend_dir, 'node_modules'))
      end
    end

    it 'does not select root package-lock.json when package_json_path is in a subdirectory' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task/frontend && npm install --production']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'package-lock.json'), '{}')

        frontend_dir = File.join(dir, 'frontend')
        FileUtils.mkdir_p(frontend_dir)
        pkg_path = File.join(frontend_dir, 'package.json')
        File.write(pkg_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(frontend_dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: pkg_path,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(frontend_dir, 'node_modules'))
      end
    end

    it 'copies nonstandard lock filename to package-lock.json with trap when using default package.json' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: [
            'sh', '-c',
            satisfy do |cmd|
              cmd.include?('cp custom-lock.json package-lock.json') &&
                cmd.include?('npm ci --production') &&
                cmd.include?('trap') &&
                cmd.include?('.package-lock.json.veltrunode.bak') &&
                !cmd.include?('.package.json.veltrunode.bak')
            end
          ]
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        pkg_path = File.join(dir, 'package.json')
        lock_path = File.join(dir, 'custom-lock.json')
        File.write(pkg_path, '{}')
        File.write(lock_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_lock_path: lock_path,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
      end
    end

    it 'stages root package-lock.json into subdirectory when explicit package_lock_path is configured' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: [
            'sh', '-c',
            satisfy do |cmd|
              cmd.include?('cd /var/task/frontend') &&
                cmd.include?('cp ../package-lock.json package-lock.json') &&
                cmd.include?('npm ci --production') &&
                cmd.include?('trap') &&
                cmd.include?('.package-lock.json.veltrunode.bak')
            end
          ]
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        root_lock = File.join(dir, 'package-lock.json')
        File.write(root_lock, '{}')

        frontend_dir = File.join(dir, 'frontend')
        FileUtils.mkdir_p(frontend_dir)
        pkg_path = File.join(frontend_dir, 'package.json')
        File.write(pkg_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(frontend_dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: pkg_path,
          package_lock_path: root_lock,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(frontend_dir, 'node_modules'))
      end
    end

    it 'uses custom package_json filename with safe backup and restore for Node.js container command' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: [
            'sh', '-c',
            satisfy do |cmd|
              cmd.include?('cp package-prod.json package.json') &&
                cmd.include?('npm install --production') &&
                cmd.include?('trap') &&
                cmd.include?('.package.json.veltrunode.bak')
            end
          ]
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        pkg_path = File.join(dir, 'package-prod.json')
        File.write(pkg_path, '{}')

        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: pkg_path,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
      end
    end

    it 'falls back to layer.build_environment package_json setting for Node.js container command' do
      layer = Veltrunode::Model::Layer.new(
        name: 'custom_node_layer',
        compatible_runtimes: ['nodejs20.x'],
        build_environment: { 'package_json' => 'packages/api/package.json' }
      )

      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task/packages/api && npm install --production']
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
          layer: layer,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(dir, 'node_modules'))
      end
    end

    it 'does not escape source_dir when package_json_path resides in a sibling directory with matching prefix' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task && npm install --production']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Npm success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |base_tmp|
        source_dir = File.join(base_tmp, 'app')
        sibling_dir = File.join(base_tmp, 'app-evil')
        FileUtils.mkdir_p(source_dir)
        FileUtils.mkdir_p(sibling_dir)
        evil_pkg = File.join(sibling_dir, 'package.json')
        File.write(evil_pkg, '{}')

        result = described_class.build(
          source_dir: source_dir,
          output_dir: File.join(source_dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          package_json_path: evil_pkg,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(source_dir, 'node_modules'))
      end
    end

    it 'does not escape source_dir when requirements_path resides in a sibling directory with matching prefix' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          command: ['sh', '-c', 'cd /var/task && pip install -r requirements.txt -t vendor/python']
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Pip success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |base_tmp|
        source_dir = File.join(base_tmp, 'app')
        sibling_dir = File.join(base_tmp, 'app-evil')
        FileUtils.mkdir_p(source_dir)
        FileUtils.mkdir_p(sibling_dir)
        evil_req = File.join(sibling_dir, 'requirements.txt')
        File.write(evil_req, "requests\n")

        result = described_class.build(
          source_dir: source_dir,
          output_dir: File.join(source_dir, 'vendor', 'python'),
          runtime: 'python3.12',
          architecture: 'x86_64',
          requirements_path: evil_req,
          container_runner: mock_container_runner
        )

        expect(result[:output_dir]).to eq(File.join(source_dir, 'vendor', 'python'))
      end
    end

    it 'selects SAM Python build image even when build_on is :amazon_linux_2023' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/build-python3.12:latest-x86_64@sha256:/),
          architecture: 'x86_64'
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'vendor', 'python'),
          runtime: 'python3.12',
          architecture: 'x86_64',
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          container_runner: mock_container_runner
        )

        expect(result[:image]).to include('build-python3.12:latest-x86_64')
        expect(result[:image]).not_to include('amazonlinux:2023')
      end
    end

    it 'selects SAM Node.js build image even when build_on is :amazon_linux_2023' do
      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/build-nodejs20.x:latest-arm64@sha256:/),
          architecture: 'arm64'
        )
      ).and_return(
        executable: 'docker',
        command: %w[docker run],
        stdout: 'Success',
        stderr: '',
        status: 0
      )

      Dir.mktmpdir do |dir|
        result = described_class.build(
          source_dir: dir,
          output_dir: File.join(dir, 'node_modules'),
          runtime: 'nodejs20.x',
          architecture: 'arm64',
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          container_runner: mock_container_runner
        )

        expect(result[:image]).to include('build-nodejs20.x:latest-arm64')
        expect(result[:image]).not_to include('amazonlinux:2023')
      end
    end
  end
end
