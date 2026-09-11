# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
require 'shellwords'
require_relative 'container_runner'
require_relative '../validation'

module Veltrunode
  module Build
    class NativeBuilder
      DEFAULT_IMAGE_DIGESTS = {
        'ruby3.3-x86_64' => 'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:' \
                            'ed67ce8c9a2288c48cb95f6c9ef2fe5be2375b4461e34bb88bb8e1ef16a87484',
        'ruby3.3-arm64' => 'public.ecr.aws/sam/build-ruby3.3:latest-arm64@sha256:' \
                           '3bc0be90a6d55ef3ac02e103a82f4556438deafbb6528fff5ca029e7947fabdf',
        'ruby3.2-x86_64' => 'public.ecr.aws/sam/build-ruby3.2:latest-x86_64@sha256:' \
                            '167caa7f1cc96a664ca2446868f125e458399b39776d03bc17c9edacb608b10d',
        'ruby3.2-arm64' => 'public.ecr.aws/sam/build-ruby3.2:latest-arm64@sha256:' \
                           '38bf3b7e2ba6dac0224f012fbda37698076cf3faf8b0a8277dd81b58df4709dd',
        'python3.12-x86_64' => 'public.ecr.aws/sam/build-python3.12:latest-x86_64@sha256:' \
                               '4f6d1c3b9b2ad0ca1618a519ef409e3c15a7da6b87e9d064e23843ce53a307b5',
        'python3.12-arm64' => 'public.ecr.aws/sam/build-python3.12:latest-arm64@sha256:' \
                              '227044c26f87e9e536eebf515b65cf2e058107e74c903565ba5d1e9c45543ad1',
        'python3.11-x86_64' => 'public.ecr.aws/sam/build-python3.11:latest-x86_64@sha256:' \
                               'af51c6d8d13347cfc2fb4c0d17638491b666704bf4b8e29ca538b46469107a05',
        'python3.11-arm64' => 'public.ecr.aws/sam/build-python3.11:latest-arm64@sha256:' \
                              '058b434bedacadac97ac898f6621eb37209334484b932fbf85dcbd00cad075bf',
        'nodejs20.x-x86_64' => 'public.ecr.aws/sam/build-nodejs20.x:latest-x86_64@sha256:' \
                               'eee793edc5cf0c5d6782fa3d83329c227c43bd66fdf0c8ba6a655c51c0b51ff2',
        'nodejs20.x-arm64' => 'public.ecr.aws/sam/build-nodejs20.x:latest-arm64@sha256:' \
                              '7a6183f6573b202fa2d542b34a97d45ea7aa5642ad80b765ee9390025d25c228',
        'nodejs18.x-x86_64' => 'public.ecr.aws/sam/build-nodejs18.x:latest-x86_64@sha256:' \
                               '3e15c7aa40ab956a0de156929493e288a1cb7919fa1a15c7cdf9b44a634361e4',
        'nodejs18.x-arm64' => 'public.ecr.aws/sam/build-nodejs18.x:latest-arm64@sha256:' \
                              '4629886314b9b5967d518cecde57df551256aa60da4bae4d7831f9f50be2644f',
        'amazonlinux2023-x86_64' => 'public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:' \
                                    '79c418a55dfcdfa1f39ca174c8206ceabb89c200aba896d6b2b7c71a068c48d9',
        'amazonlinux2023-arm64' => 'public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:' \
                                   '574a1ca288afe7e0b58f05fbeedc71fd57d78551ea2059129db7ecf692b8bd6a'
      }.freeze

      class << self
        def build(
          source_dir:,
          output_dir:,
          runtime: 'ruby3.3',
          architecture: 'x86_64',
          build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
          custom_image: nil,
          runner_executable: nil,
          container_runner: ContainerRunner,
          requirements_path: nil,
          package_json_path: nil,
          layer: nil
        )
          new(
            source_dir: source_dir,
            output_dir: output_dir,
            runtime: runtime,
            architecture: architecture,
            build_on: build_on,
            custom_image: custom_image,
            runner_executable: runner_executable,
            container_runner: container_runner,
            requirements_path: requirements_path,
            package_json_path: package_json_path,
            layer: layer
          ).build
        end
      end

      attr_reader :source_dir, :output_dir, :runtime, :architecture, :build_on, :image, :image_digest,
                  :requirements_path, :package_json_path, :layer

      def initialize(
        source_dir:,
        output_dir:,
        runtime: 'ruby3.3',
        architecture: 'x86_64',
        build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
        custom_image: nil,
        runner_executable: nil,
        container_runner: ContainerRunner,
        requirements_path: nil,
        package_json_path: nil,
        layer: nil
      )
        @source_dir = File.expand_path(source_dir.to_s)
        @output_dir = File.expand_path(output_dir.to_s)
        @runtime = runtime.to_s.freeze
        @architecture = architecture.to_s.freeze
        @build_on = build_on
        @runner_executable = runner_executable
        @container_runner = container_runner
        @image = resolve_image(custom_image)
        @image_digest = extract_digest(@image)
        @layer = layer
        @requirements_path = resolve_requirements_path(requirements_path)
        @package_json_path = resolve_package_json_path(package_json_path)

        validate_output_dir!

        freeze
      end

      def build
        FileUtils.mkdir_p(@output_dir)

        container_command = resolve_container_command
        volume_mounts = {
          @source_dir => '/var/task'
        }
        environment = resolve_environment

        result = @container_runner.run(
          image: @image,
          command: container_command,
          environment: environment,
          volume_mounts: volume_mounts,
          architecture: @architecture,
          workdir: '/var/task',
          runner_executable: @runner_executable
        )

        {
          image: @image,
          image_digest: @image_digest,
          output_dir: @output_dir,
          result: result
        }
      end

      private

      def resolve_expected_output_dirs
        if @runtime.start_with?('python')
          [File.join(@source_dir, 'vendor', 'python')]
        elsif @runtime.start_with?('node')
          working_dir = resolve_node_working_dir
          dirs = [File.join(@source_dir, 'node_modules')]
          dirs.unshift(File.join(@source_dir, working_dir, 'node_modules')) if working_dir && working_dir != '.'
          dirs.uniq
        else
          [File.join(@source_dir, 'vendor', 'bundle')]
        end
      end

      def validate_output_dir!
        expected_dirs = resolve_expected_output_dirs
        return if expected_dirs.include?(@output_dir)

        raise ValidationError,
              "output_dir must be '#{expected_dirs.first}' when using NativeBuilder (got: '#{@output_dir}')"
      end

      def resolve_requirements_path(explicit_path)
        if explicit_path && !explicit_path.to_s.strip.empty?
          explicit_path.to_s.strip
        elsif @layer.respond_to?(:build_environment) && @layer.build_environment.is_a?(Hash)
          req = @layer.build_environment['requirements'] || @layer.build_environment[:requirements]
          req&.to_s&.strip
        end
      end

      def resolve_package_json_path(explicit_path)
        if explicit_path && !explicit_path.to_s.strip.empty?
          explicit_path.to_s.strip
        elsif @layer.respond_to?(:build_environment) && @layer.build_environment.is_a?(Hash)
          pkg = @layer.build_environment['package_json'] || @layer.build_environment[:package_json]
          pkg&.to_s&.strip
        end
      end

      def resolve_python_requirements_file
        return 'requirements.txt' if @requirements_path.nil? || @requirements_path.to_s.strip.empty?

        req_str = @requirements_path.to_s.strip
        abs_path = File.expand_path(req_str, @source_dir)
        if abs_path.start_with?(@source_dir)
          begin
            rel = Pathname.new(abs_path).relative_path_from(Pathname.new(@source_dir)).to_s
            return rel unless rel.empty?
          rescue ArgumentError
            # Fallback to req_str
          end
        end

        req_str
      end

      def resolve_node_working_dir
        return '.' if @package_json_path.nil? || @package_json_path.to_s.strip.empty?

        pkg_str = @package_json_path.to_s.strip
        abs_path = File.expand_path(pkg_str, @source_dir)
        dir_path = File.directory?(abs_path) ? abs_path : File.dirname(abs_path)

        if dir_path.start_with?(@source_dir)
          begin
            rel = Pathname.new(dir_path).relative_path_from(Pathname.new(@source_dir)).cleanpath.to_s
            return rel unless rel.empty?
          rescue ArgumentError
            # Fallback
          end
        end

        '.'
      end

      def resolve_node_package_file
        return 'package.json' if @package_json_path.nil? || @package_json_path.to_s.strip.empty?

        pkg_str = @package_json_path.to_s.strip
        abs_path = File.expand_path(pkg_str, @source_dir)
        File.directory?(abs_path) ? 'package.json' : File.basename(abs_path)
      end

      def resolve_container_command
        if @runtime.start_with?('python')
          req_file = resolve_python_requirements_file
          [
            'sh', '-c',
            "cd /var/task && pip install -r #{Shellwords.shellescape(req_file)} -t vendor/python"
          ]
        elsif @runtime.start_with?('node')
          working_dir = resolve_node_working_dir
          pkg_file = resolve_node_package_file
          cd_target = working_dir == '.' ? '/var/task' : "/var/task/#{working_dir}"
          cmd = if pkg_file == 'package.json'
                  "cd #{Shellwords.shellescape(cd_target)} && npm install --production"
                else
                  escaped_cd = Shellwords.shellescape(cd_target)
                  escaped_pkg = Shellwords.shellescape(pkg_file)
                  "cd #{escaped_cd} && " \
                    'if [ -e package.json ]; then ' \
                    'cp -p package.json .package.json.veltrunode.bak && ' \
                    "trap 'mv -f .package.json.veltrunode.bak package.json' EXIT; " \
                    'else ' \
                    "trap 'rm -f package.json' EXIT; " \
                    'fi && ' \
                    "cp #{escaped_pkg} package.json && npm install --production"
                end
          ['sh', '-c', cmd]
        else
          [
            'sh', '-c',
            'cd /var/task && bundle config set --local path vendor/bundle && bundle install'
          ]
        end
      end

      def resolve_environment
        if @runtime.start_with?('python')
          {
            'PIP_DISABLE_PIP_VERSION_CHECK' => '1',
            'PIP_NO_CACHE_DIR' => '1'
          }
        elsif @runtime.start_with?('node')
          {
            'NODE_ENV' => 'production'
          }
        else
          {
            'BUNDLE_SILENCE_ROOT_WARNING' => '1'
          }
        end
      end

      def resolve_image(custom_image)
        return custom_image.to_s.freeze if custom_image && !custom_image.to_s.strip.empty?

        runtime_key = "#{@runtime}-#{@architecture}"
        if (@runtime.start_with?('python') || @runtime.start_with?('node')) &&
           DEFAULT_IMAGE_DIGESTS.key?(runtime_key)
          return DEFAULT_IMAGE_DIGESTS[runtime_key].freeze
        end

        build_on_str = @build_on.to_s.downcase
        if build_on_str.include?('amazon_linux_2023') || build_on_str.include?('al2023')
          al_key = "amazonlinux2023-#{@architecture}"
          return DEFAULT_IMAGE_DIGESTS[al_key].freeze if DEFAULT_IMAGE_DIGESTS.key?(al_key)
        end

        return DEFAULT_IMAGE_DIGESTS[runtime_key].freeze if DEFAULT_IMAGE_DIGESTS.key?(runtime_key)

        al_key = "amazonlinux2023-#{@architecture}"
        return DEFAULT_IMAGE_DIGESTS[al_key].freeze if DEFAULT_IMAGE_DIGESTS.key?(al_key)

        DEFAULT_IMAGE_DIGESTS['amazonlinux2023-x86_64'].freeze
      end

      def extract_digest(img)
        if img.include?('@sha256:')
          img.split('@').last
        else
          "sha256:#{Digest::SHA256.hexdigest(img)}"
        end
      end
    end
  end
end
