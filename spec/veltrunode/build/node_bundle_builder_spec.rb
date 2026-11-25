# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'veltrunode/build/node_bundle_builder'
require 'veltrunode/build/archive_result'
require 'veltrunode/build/function_packager'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Build::NodeBundleBuilder do
  let(:tmpdir) { Dir.mktmpdir('veltrunode-node-bundle-spec-') }
  let(:output_dir) { File.join(tmpdir, 'build', 'artifacts', 'functions') }
  let(:mock_archiver) do
    Class.new do
      class << self
        attr_accessor :last_staged_files, :last_files_content

        def archive(source_dir:, output_path:, includes: nil, excludes: nil) # rubocop:disable Lint/UnusedMethodArgument
          FileUtils.mkdir_p(File.dirname(output_path))
          @last_staged_files = Dir.glob('**/*', base: source_dir).select do |rel|
            File.file?(File.join(source_dir, rel))
          end.sort
          @last_files_content = @last_staged_files.to_h do |rel|
            [rel, File.read(File.join(source_dir, rel))]
          end
          payload = @last_staged_files.map { |f| "#{f}:#{@last_files_content[f]}" }.join("\n")
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

  before do
    FileUtils.mkdir_p(File.join(tmpdir, 'src'))
    File.write(File.join(tmpdir, 'src', 'handler.ts'), <<~TS)
      import type { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';

      export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
        return { statusCode: 200, body: JSON.stringify({ ok: true, path: event.path }) };
      };
    TS
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe 'esbuild TypeScript bundling and Source Map output' do
    it 'invokes esbuild with tree-shaking, target=node20, and --sourcemap and packages handler.js and handler.js.map' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ts_api',
        runtime: 'nodejs20.x',
        entry: 'src/handler.ts',
        sourcemap: true,
        minify: true,
        external: ['@aws-sdk/*']
      )

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        output_dir: output_dir,
        runner_executable: 'esbuild',
        command_runner: runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(executed_commands.size).to eq(1)
      cmd = executed_commands.first
      expect(cmd).to include(
        'esbuild',
        'src/handler.ts',
        '--bundle',
        '--platform=node',
        '--target=node20',
        '--format=cjs',
        '--tree-shaking=true',
        '--minify',
        '--sourcemap',
        '--external:@aws-sdk/*'
      )
      expect(cmd.last).to match(%r{--outfile=.*/handler\.js\z})

      expect(result.function_name).to eq('ts_api')
      expect(result.entries).to eq(%w[handler.js handler.js.map])
      expect(mock_archiver.last_files_content['handler.js']).to include('sourceMappingURL=handler.js.map')
      expect(mock_archiver.last_files_content['handler.js.map']).to include('"sources":["src/handler.ts"]')
    end

    it 'supports inline sourcemap (--sourcemap=inline) without generating external .map file' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'ts_inline',
        runtime: 'nodejs20.x',
        entry: 'src/handler.ts',
        sourcemap: :inline
      )

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        output_dir: output_dir,
        runner_executable: 'esbuild',
        command_runner: runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(executed_commands.first).to include('--sourcemap=inline')
      expect(result.entries).to eq(['handler.js'])
      expect(mock_archiver.last_files_content['handler.js']).to include(
        'sourceMappingURL=data:application/json;base64,'
      )
    end

    it 'supports Bun bundler (bun build) with external sourcemap' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'bun_api',
        runtime: 'nodejs20.x',
        bun: { entry: 'src/handler.ts', sourcemap: :external, minify: true, external: ['@aws-sdk/*'] }
      )

      executed_commands = []
      runner = lambda do |cmd, chdir: nil| # rubocop:disable Lint/UnusedBlockArgument
        executed_commands << cmd
        ['', '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      result = described_class.build(
        function: fn,
        source_dir: tmpdir,
        output_dir: output_dir,
        runner_executable: 'bun',
        command_runner: runner,
        archiver: mock_archiver,
        no_cache: true
      )

      expect(executed_commands.first).to include(
        'bun', 'build', 'src/handler.ts', '--target=node', '--format=cjs', '--minify', '--sourcemap=external'
      )
      expect(result.entries).to eq(%w[handler.js handler.js.map])
    end

    it 'raises ValidationError with VLT-BUILD-ENTRY-NOT-FOUND when entry file is missing' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'missing_ts',
        runtime: 'nodejs20.x',
        entry: 'src/non_existent.ts'
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
        expect(err.diagnostics.first.code).to eq('VLT-BUILD-ENTRY-NOT-FOUND')
      end)
    end
  end
end
