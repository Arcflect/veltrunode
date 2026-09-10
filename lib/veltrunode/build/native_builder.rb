# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'container_runner'
require_relative '../validation'

module Veltrunode
  module Build
    class NativeBuilder
      DEFAULT_IMAGE_DIGESTS = {
        'ruby3.3-x86_64' => 'public.ecr.aws/sam/build-ruby3.3:latest-x86_64@sha256:' \
                            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'ruby3.3-arm64' => 'public.ecr.aws/sam/build-ruby3.3:latest-arm64@sha256:' \
                           '123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0',
        'ruby3.2-x86_64' => 'public.ecr.aws/sam/build-ruby3.2:latest-x86_64@sha256:' \
                            '23456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01',
        'ruby3.2-arm64' => 'public.ecr.aws/sam/build-ruby3.2:latest-arm64@sha256:' \
                           '3456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef012',
        'python3.12-x86_64' => 'public.ecr.aws/sam/build-python3.12:latest-x86_64@sha256:' \
                               '6789abcdef0123456789abcdef0123456789abcdef0123456789abcdef012345',
        'python3.12-arm64' => 'public.ecr.aws/sam/build-python3.12:latest-arm64@sha256:' \
                              '789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456',
        'python3.11-x86_64' => 'public.ecr.aws/sam/build-python3.11:latest-x86_64@sha256:' \
                               '89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567',
        'python3.11-arm64' => 'public.ecr.aws/sam/build-python3.11:latest-arm64@sha256:' \
                              '9abcdef0123456789abcdef0123456789abcdef0123456789abcdef012345678',
        'nodejs20.x-x86_64' => 'public.ecr.aws/sam/build-nodejs20.x:latest-x86_64@sha256:' \
                               'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
        'nodejs20.x-arm64' => 'public.ecr.aws/sam/build-nodejs20.x:latest-arm64@sha256:' \
                              'bcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789a',
        'nodejs18.x-x86_64' => 'public.ecr.aws/sam/build-nodejs18.x:latest-x86_64@sha256:' \
                               'cdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab',
        'nodejs18.x-arm64' => 'public.ecr.aws/sam/build-nodejs18.x:latest-arm64@sha256:' \
                              'def0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc',
        'amazonlinux2023-x86_64' => 'public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:' \
                                    '456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123',
        'amazonlinux2023-arm64' => 'public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:' \
                                   '56789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234'
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
          container_runner: ContainerRunner
        )
          new(
            source_dir: source_dir,
            output_dir: output_dir,
            runtime: runtime,
            architecture: architecture,
            build_on: build_on,
            custom_image: custom_image,
            runner_executable: runner_executable,
            container_runner: container_runner
          ).build
        end
      end

      attr_reader :source_dir, :output_dir, :runtime, :architecture, :build_on, :image, :image_digest

      def initialize(
        source_dir:,
        output_dir:,
        runtime: 'ruby3.3',
        architecture: 'x86_64',
        build_on: :amazon_linux_2023, # rubocop:disable Naming/VariableNumber
        custom_image: nil,
        runner_executable: nil,
        container_runner: ContainerRunner
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

      def resolve_expected_output_dir
        if @runtime.start_with?('python')
          File.join(@source_dir, 'vendor', 'python')
        elsif @runtime.start_with?('node')
          File.join(@source_dir, 'node_modules')
        else
          File.join(@source_dir, 'vendor', 'bundle')
        end
      end

      def validate_output_dir!
        expected_output_dir = resolve_expected_output_dir
        return if @output_dir == expected_output_dir

        raise ValidationError,
              "output_dir must be '#{expected_output_dir}' when using NativeBuilder (got: '#{@output_dir}')"
      end

      def resolve_container_command
        if @runtime.start_with?('python')
          [
            'sh', '-c',
            'cd /var/task && pip install -r requirements.txt -t vendor/python'
          ]
        elsif @runtime.start_with?('node')
          [
            'sh', '-c',
            'cd /var/task && npm install --production'
          ]
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

        build_on_str = @build_on.to_s.downcase
        if build_on_str.include?('amazon_linux_2023') || build_on_str.include?('al2023')
          al_key = "amazonlinux2023-#{@architecture}"
          return DEFAULT_IMAGE_DIGESTS[al_key].freeze if DEFAULT_IMAGE_DIGESTS.key?(al_key)
        end

        key = "#{@runtime}-#{@architecture}"
        return DEFAULT_IMAGE_DIGESTS[key].freeze if DEFAULT_IMAGE_DIGESTS.key?(key)

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
