# frozen_string_literal: true

require 'open3'
require_relative '../validation'
require_relative '../diagnostics'

module Veltrunode
  module Build
    class ContainerRunner
      PLATFORM_MAP = {
        'x86_64' => 'linux/amd64',
        'amd64' => 'linux/amd64',
        'arm64' => 'linux/arm64',
        'aarch64' => 'linux/arm64'
      }.freeze

      attr_reader :image, :command, :environment, :volume_mounts, :architecture, :executable

      class << self
        def detect_executable
          %w[docker podman].find { |cmd| executable_in_path?(cmd) }
        end

        def executable_in_path?(cmd)
          ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |path|
            exe = File.join(path, cmd)
            File.executable?(exe) && !File.directory?(exe)
          end
        end

        def validate_runtime_available!
          executable = detect_executable
          return executable if executable

          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-DOCKER-NOT-FOUND',
            severity: :error,
            summary: 'Container runtime (docker or podman) not found in PATH.',
            suggested_action: 'Install Docker or Podman and ensure it is available ' \
                              'in your PATH to build native extensions.',
            evidence: { 'path' => ENV.fetch('PATH', nil) }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end

        def run(image:, command:, environment: {}, volume_mounts: {}, architecture: 'x86_64', runner_executable: nil)
          new(
            image: image,
            command: command,
            environment: environment,
            volume_mounts: volume_mounts,
            architecture: architecture,
            runner_executable: runner_executable
          ).run
        end
      end

      def initialize(
        image:,
        command:,
        environment: {},
        volume_mounts: {},
        architecture: 'x86_64',
        runner_executable: nil
      )
        @executable = runner_executable || self.class.validate_runtime_available!
        @image = image.to_s.freeze
        @command = Array(command).map(&:to_s).freeze
        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @volume_mounts = volume_mounts.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @architecture = architecture.to_s.freeze
        freeze
      end

      def build_cli_command
        cmd = [@executable, 'run', '--rm']

        platform = PLATFORM_MAP[@architecture] || 'linux/amd64'
        cmd << '--platform' << platform

        @environment.each do |k, v|
          cmd << '-e' << "#{k}=#{v}"
        end

        @volume_mounts.each do |host_path, container_path|
          cmd << '-v' << "#{File.expand_path(host_path)}:#{container_path}"
        end

        cmd << @image
        cmd.concat(@command)
        cmd
      end

      def run
        cli_cmd = build_cli_command
        stdout_str, stderr_str, status = Open3.capture3(*cli_cmd)

        unless status.success?
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-BUILD-001',
            severity: :error,
            summary: "Native container build failed using #{@executable}: exit code #{status.exitstatus}",
            suggested_action: "Check container build logs or verify build environment for image '#{@image}'.",
            evidence: {
              'command' => cli_cmd.join(' '),
              'stdout' => stdout_str,
              'stderr' => stderr_str,
              'exitstatus' => status.exitstatus
            }
          )
          raise ValidationError.new(diag.summary, diagnostics: [diag])
        end

        {
          executable: @executable,
          command: cli_cmd,
          stdout: stdout_str,
          stderr: stderr_str,
          status: status.exitstatus
        }
      end
    end
  end
end
