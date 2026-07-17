# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/cli'
require 'stringio'

RSpec.describe Veltrunode::CLI::Router do
  describe '.run' do
    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }

    before do
      # Avoid modifying the actual stdout/stderr streams
      allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
      allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    end

    def run_cli(args)
      stdout.string.clear
      stderr.string.clear
      Veltrunode::CLI::Router.run(args)
    end

    it 'displays help when no arguments are provided' do
      code = run_cli([])
      expect(code).to eq(0)
      expect(stdout.string).to include('Usage:')
    end

    it 'displays help when --help is provided' do
      code = run_cli(['--help'])
      expect(code).to eq(0)
      expect(stdout.string).to include('Usage:')
    end

    it 'displays version when --version is provided' do
      code = run_cli(['--version'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq(Veltrunode::VERSION)
    end

    it 'displays version in JSON format when --format json is provided' do
      code = run_cli(['--version', '--format', 'json'])
      expect(code).to eq(0)
      json = JSON.parse(stdout.string)
      expect(json['version']).to eq(Veltrunode::VERSION)
    end

    it 'returns exit code 2 and error message for unknown command' do
      code = run_cli(['invalid_subcommand'])
      expect(code).to eq(2)
      expect(stderr.string).to include("Unknown command 'invalid_subcommand'")
    end

    it 'runs init command stub' do
      code = run_cli(['init'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Project initialized.')
    end

    it 'runs validate command stub' do
      code = run_cli(['validate'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Validation successful.')
    end

    it 'runs build command stub' do
      code = run_cli(['build'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Build successful.')
    end

    it 'runs plan command stub' do
      code = run_cli(['plan'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Plan generated.')
    end

    it 'runs deploy command stub' do
      code = run_cli(['deploy'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Deployment successful.')
    end

    it 'runs invoke local command stub' do
      code = run_cli(%w[invoke local my-func])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Invoked local function: my-func.')
    end

    it 'runs destroy command stub' do
      code = run_cli(['destroy'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Stack destroyed.')
    end

    it 'runs efs verify command stub' do
      code = run_cli(%w[efs verify my-efs])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('EFS verification successful for: my-efs.')
    end

    it 'runs layer inspect command stub' do
      code = run_cli(%w[layer inspect my-layer])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Inspected layer: my-layer.')
    end

    it 'runs schedule preview command stub' do
      code = run_cli(%w[schedule preview my-schedule])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Previewed schedule: my-schedule.')
    end
  end
end
