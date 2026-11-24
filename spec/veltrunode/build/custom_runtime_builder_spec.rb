# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/build/custom_runtime_builder'
require 'veltrunode/build/archive_result'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Build::CustomRuntimeBuilder do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-custom-runtime-spec-') }
  let(:output_dir) { File.join(tmpdir, 'build', 'artifacts', 'functions') }
  let(:mock_container_runner) { class_double(Veltrunode::Build::ContainerRunner) }
  let(:mock_archiver) do
    Class.new do
      class << self
        attr_accessor :last_staged_files, :last_bootstrap_mode

        def archive(source_dir:, output_path:, includes: nil, excludes: nil) # rubocop:disable Lint/UnusedMethodArgument
          FileUtils.mkdir_p(File.dirname(output_path))
          bs_path = File.join(source_dir, 'bootstrap')
          @last_staged_files = Dir.glob('**/*', base: source_dir).sort
          @last_bootstrap_mode = File.exist?(bs_path) ? (File.stat(bs_path).mode & 0o777) : nil
          payload = File.exist?(bs_path) ? File.binread(bs_path) : ''
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

  describe 'Rust / Cargo pipeline (provided.al2023)' do
    before do
      File.write(File.join(tmpdir, 'Cargo.toml'), <<~TOML)
        [package]
        name = "ultra_fast_worker"
        version = "0.1.0"
        edition = "2021"
      TOML
      File.write(File.join(tmpdir, 'Cargo.lock'), "# lockfile\n")
      FileUtils.mkdir_p(File.join(tmpdir, 'src'))
      File.write(File.join(tmpdir, 'src', 'main.rs'), "fn main() {}\n")
    end

    it 'cross-compiles static musl bootstrap inside Docker container for arm64 and places bootstrap at ZIP root' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'rust_worker',
        runtime: 'provided.al2023',
        architecture: :arm64,
        cargo: { docker: true }
      )

      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/rust:1\.80-alpine@sha256:/),
          architecture: 'arm64',
          workdir: '/var/task',
          environment: hash_including(
            'CARGO_INCREMENTAL' => '0',
            'SOURCE_DATE_EPOCH' => '1704067200',
            'RUSTFLAGS' => include('-C target-feature=+crt-static', '--remap-path-prefix=/var/task=/var/task')
          ),
          command: [
            'sh', '-c',
            include(
              'cargo build --release --target aarch64-unknown-linux-musl --locked',
              'cp target/aarch64-unknown-linux-musl/release/ultra_fast_worker bootstrap',
              'chmod 0755 bootstrap'
            )
          ]
        )
      ) do
        target_bin = File.join(
          tmpdir, 'target', 'aarch64-unknown-linux-musl', 'release', 'ultra_fast_worker'
        )
        FileUtils.mkdir_p(File.dirname(target_bin))
        File.binwrite(target_bin, "ELF_ARM64_MUSL_BINARY\n")
        { status: 0 }
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        output_dir: output_dir,
        container_runner: mock_container_runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(result.function_name).to eq('rust_worker')
      expect(result.entries).to eq(['bootstrap'])
      expect(mock_archiver.last_staged_files).to eq(['bootstrap'])
      expect(mock_archiver.last_bootstrap_mode).to eq(0o755)
      expect(File.exist?(result.zip_path)).to be(true)
    end

    it 'computes deterministic content_hash across builds with identical Cargo inputs' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'rust_worker',
        runtime: 'provided.al2023',
        architecture: :x86_64,
        cargo: { bin: 'ultra_fast_worker', docker: false }
      )

      b1 = described_class.new(function: fn, source_dir: tmpdir, output_dir: output_dir, execute_build: false)
      b2 = described_class.new(function: fn, source_dir: tmpdir, output_dir: output_dir, execute_build: false)

      expect(b1.resolve_target_triple).to eq('x86_64-unknown-linux-musl')
      expect(b1.calculate_content_hash).to eq(b2.calculate_content_hash)
    end

    it 'raises ValidationError with VLT-BUILD-CARGO-MANIFEST-NOT-FOUND when Cargo.toml is missing' do
      FileUtils.rm_f(File.join(tmpdir, 'Cargo.toml'))
      fn = Veltrunode::Model::Function.new(
        logical_name: 'rust_worker',
        cargo: { manifest_path: './Cargo.toml' }
      )

      expect do
        described_class.build(
          function: fn,
          source_dir: tmpdir,
          output_dir: output_dir,
          archiver: mock_archiver,
          execute_build: false
        )
      end.to(raise_error(Veltrunode::ValidationError) do |err|
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-CARGO-MANIFEST-NOT-FOUND')
      end)
    end
  end

  describe 'Go pipeline (provided.al2023)' do
    before do
      File.write(File.join(tmpdir, 'go.mod'), "module example.com/fast-go\n\ngo 1.22\n")
      File.write(File.join(tmpdir, 'main.go'), "package main\nfunc main() {}\n")
    end

    it 'cross-compiles static Go bootstrap with CGO_ENABLED=0 and deterministic flags inside Docker container' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'go_worker',
        runtime: 'provided.al2023',
        architecture: :arm64,
        go: { package: '.', docker: true }
      )

      expect(mock_container_runner).to receive(:run).with(
        hash_including(
          image: match(/golang:1\.22-alpine@sha256:/),
          architecture: 'arm64',
          environment: hash_including(
            'CGO_ENABLED' => '0',
            'GOOS' => 'linux',
            'GOARCH' => 'arm64',
            'SOURCE_DATE_EPOCH' => '1704067200'
          ),
          command: [
            'sh', '-c',
            include(
              'go build -trimpath -buildvcs=false',
              '-tags netgo,osusergo -o bootstrap .',
              'chmod 0755 bootstrap'
            )
          ]
        )
      ) do
        File.binwrite(File.join(tmpdir, 'bootstrap'), "ELF_GO_ARM64_STATIC_BINARY\n")
        { status: 0 }
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        output_dir: output_dir,
        container_runner: mock_container_runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(result.function_name).to eq('go_worker')
      expect(result.entries).to eq(['bootstrap'])
      expect(mock_archiver.last_bootstrap_mode).to eq(0o755)
    end
  end
end
