# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/build/dockerless_builder'
require 'veltrunode/build/native_builder'
require 'veltrunode/model/layer'

RSpec.describe Veltrunode::Build::DockerlessBuilder do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-dockerless-spec-') }
  let(:output_dir) { File.join(tmpdir, 'vendor', 'bundle') }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe 'Dockerless fallback, host bundler packaging, and external prebuilt binary import' do
    it 'imports external prebuilt binaries into output_dir and emits VLT-BUILD-DOCKER-FALLBACK warning' do
      prebuilt_dir = File.join(tmpdir, 'vendor', 'prebuilt')
      native_gem_dir = File.join(prebuilt_dir, 'ruby', '3.3.0', 'gems', 'nokogiri-1.16.0')
      FileUtils.mkdir_p(native_gem_dir)
      File.write(File.join(native_gem_dir, 'nokogiri.so'), 'ELF_BINARY_DATA')

      result = described_class.build(
        source_dir: tmpdir,
        output_dir: output_dir,
        runtime: 'ruby3.3',
        architecture: 'arm64',
        prebuilt_path: prebuilt_dir,
        no_docker: true
      )

      expect(result[:strategy]).to eq(:prebuilt)
      expect(result[:image_digest]).to match(/\Asha256:[0-9a-f]{64}\z/)
      copied_so = File.join(output_dir, 'ruby', '3.3.0', 'gems', 'nokogiri-1.16.0', 'nokogiri.so')
      expect(File.exist?(copied_so)).to be(true)

      diag = result[:diagnostics].first
      expect(diag.code).to eq('VLT-BUILD-DOCKER-FALLBACK')
      expect(diag.severity).to eq(:warning)
      expect(diag.evidence['strategy']).to eq('prebuilt')
    end

    it 'falls back to host bundler packaging with local vendor/cache when --no-docker is enabled' do
      cache_dir = File.join(tmpdir, 'vendor', 'cache')
      FileUtils.mkdir_p(cache_dir)
      File.write(File.join(cache_dir, 'pg-1.5.6.gem'), 'GEM_BINARY')

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['Bundle complete!', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        source_dir: tmpdir,
        output_dir: output_dir,
        runtime: 'ruby3.3',
        architecture: 'x86_64',
        no_docker: true,
        command_runner: runner
      )

      expect(result[:strategy]).to eq(:host)
      expect(executed_commands.size).to eq(1)
      expect(executed_commands.first.last).to include('bundle config set --local cache_all true')
      expect(executed_commands.first.last).to include('bundle install --local')

      cached_gem = File.join(output_dir, 'ruby', '3.3.0', 'cache', 'pg-1.5.6.gem')
      expect(File.exist?(cached_gem)).to be(true)

      diag = result[:diagnostics].first
      expect(diag.code).to eq('VLT-BUILD-DOCKER-FALLBACK')
      expect(diag.severity).to eq(:warning)
      expect(diag.summary).to include('--no-docker')
    end

    it 'falls back to rootless container runtime (podman) when Docker daemon is unavailable' do
      mock_runner = class_double(Veltrunode::Build::ContainerRunner)
      allow(mock_runner).to receive(:detect_rootless_executable).and_return('podman')
      expect(mock_runner).to receive(:run).with(
        hash_including(
          runner_executable: 'podman',
          architecture: 'arm64'
        )
      ).and_return(executable: 'podman', status: 0)

      result = described_class.build(
        source_dir: tmpdir,
        output_dir: output_dir,
        runtime: 'ruby3.3',
        architecture: 'arm64',
        no_docker: false,
        prefer_rootless: true,
        container_runner: mock_runner
      )

      expect(result[:strategy]).to eq(:rootless_container)
      expect(result[:executable]).to eq('podman')
      expect(result[:diagnostics].first.code).to eq('VLT-BUILD-DOCKER-FALLBACK')
    end

    it 'delegates from NativeBuilder.build when no_docker: true or fallback_on_missing_docker: true is set' do
      mock_runner = class_double(Veltrunode::Build::ContainerRunner)
      diag = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-BUILD-DOCKER-NOT-FOUND',
        severity: :error,
        summary: 'Container runtime not found in PATH.',
        suggested_action: 'Install Docker or Podman.'
      )
      allow(mock_runner).to receive(:run).and_raise(
        Veltrunode::ValidationError.new(diag.summary, diagnostics: [diag])
      )
      allow(mock_runner).to receive(:detect_rootless_executable).and_return(nil)

      result = Veltrunode::Build::NativeBuilder.build(
        source_dir: tmpdir,
        output_dir: output_dir,
        runtime: 'ruby3.3',
        architecture: 'x86_64',
        container_runner: mock_runner,
        fallback_on_missing_docker: true
      )

      expect(result[:strategy]).to eq(:host)
      expect(result[:diagnostics].first.code).to eq('VLT-BUILD-DOCKER-FALLBACK')
    end

    it 'raises ValidationError with VLT-BUILD-PREBUILT-NOT-FOUND when explicit prebuilt_path does not exist' do
      expect do
        described_class.build(
          source_dir: tmpdir,
          output_dir: output_dir,
          prebuilt_path: File.join(tmpdir, 'non_existent_prebuilt'),
          no_docker: true
        )
      end.to(raise_error(Veltrunode::ValidationError) do |err|
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-PREBUILT-NOT-FOUND')
      end)
    end

    it 'passes no_docker: true through Build::Pipeline to LayerPackager and collects fallback diagnostics' do
      require 'veltrunode/build/pipeline'
      require 'veltrunode/dsl'

      prebuilt_dir = File.join(tmpdir, 'vendor', 'prebuilt')
      FileUtils.mkdir_p(File.join(prebuilt_dir, 'ruby', '3.3.0', 'gems', 'oj-3.16.0'))
      File.write(File.join(prebuilt_dir, 'ruby', '3.3.0', 'gems', 'oj-3.16.0', 'oj.so'), 'BINARY')

      app = Veltrunode.application 'dockerless-app' do
        aws region: 'ap-northeast-1', artifact_bucket: 'dockerless-artifacts'
        stage :dev
        runtime ruby: '3.3', architecture: :x86_64

        layer :native_gems do
          build_on 'amazon_linux_2023'
          prebuilt prebuilt_dir
        end

        function :api do
          handler 'handler.call'
          attach_layer :native_gems
        end
      end

      fallback_diag = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-BUILD-DOCKER-FALLBACK',
        severity: :warning,
        summary: 'Docker build explicitly disabled (--no-docker).',
        suggested_action: 'Supply prebuilt Linux binaries for Lambda.'
      )
      mock_layer_res = instance_double(
        Veltrunode::Build::LayerPackageResult,
        layer_name: 'native_gems',
        zip_path: File.join(tmpdir, 'layers', 'native_gems.zip'),
        sha256: 'a' * 64,
        content_hash: 'b' * 64,
        bytesize: 1024,
        cached?: false,
        diagnostics: [fallback_diag]
      )
      mock_func_res = instance_double(
        Veltrunode::Build::PackageResult,
        function_name: 'api',
        zip_path: File.join(tmpdir, 'functions', 'api.zip'),
        sha256: 'c' * 64,
        content_hash: 'd' * 64,
        bytesize: 512,
        cached?: false,
        diagnostics: []
      )
      allow(Veltrunode::Build::LayerPackager).to receive(:package).and_return(mock_layer_res)
      allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_return(mock_func_res)

      pipeline_out = File.join(tmpdir, '.veltrunode', 'build')
      res = Veltrunode::Build::Pipeline.execute(
        app,
        source_dir: tmpdir,
        output_dir: pipeline_out,
        no_docker: true
      )

      expect(Veltrunode::Build::LayerPackager).to have_received(:package).with(
        hash_including(no_docker: true)
      )
      expect(res.diagnostics.map(&:code)).to include('VLT-BUILD-DOCKER-FALLBACK')
    end
  end
end
