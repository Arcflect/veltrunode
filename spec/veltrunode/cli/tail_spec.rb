# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/log_streamer'

RSpec.describe 'CLI veltrunode tail' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:worker_func) do
    Veltrunode::Model::Function.new(
      'worker',
      handler: 'app.handler',
      runtime: 'ruby3.2'
    )
  end

  let(:api_func) do
    Veltrunode::Model::Function.new(
      'api',
      handler: 'api.handler',
      runtime: 'ruby3.2'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'log-tail-app',
      region: 'ap-northeast-1',
      stage: 'staging',
      functions: [worker_func, api_func]
    )
  end

  before do
    allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
    allow($stdout).to receive(:print) { |val| stdout.print(val) }
    allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    allow(Veltrunode::SettingsLoader).to receive(:load).and_return(application)
  end

  def run_cli(args)
    Veltrunode::CLI::Router.run(args)
  end

  describe 'argument validation' do
    it 'fails with exit code 2 when function name is missing' do
      exit_code = run_cli(['tail'])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_INVALID_INPUT)
      expect(stderr.string).to include('Function name is required for tail command.')
    end

    it 'outputs JSON error when --format json is specified without function name' do
      exit_code = run_cli(['tail', '--format', 'json'])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_INVALID_INPUT)

      parsed = JSON.parse(stderr.string)
      expect(parsed['status']).to eq('error')
      expect(parsed['data']['message']).to include('Function name is required')
    end
  end

  describe 'single function tailing' do
    it 'creates LogStreamer and calls stream' do
      mock_streamer = instance_double(Veltrunode::AWS::LogStreamer)
      expect(Veltrunode::AWS::LogStreamer).to receive(:new).with(
        targets: ['worker'],
        region: 'ap-northeast-1',
        filter_pattern: nil,
        since: nil,
        follow: false,
        format: :text
      ).and_return(mock_streamer)

      expect(mock_streamer).to receive(:stream).and_return(1)

      exit_code = run_cli(%w[tail worker --no-follow])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)
    end
  end

  describe 'multiple functions tailing' do
    it 'passes multiple targets to LogStreamer' do
      mock_streamer = instance_double(Veltrunode::AWS::LogStreamer)
      expect(Veltrunode::AWS::LogStreamer).to receive(:new).with(
        targets: %w[api worker],
        region: 'ap-northeast-1',
        filter_pattern: nil,
        since: nil,
        follow: true,
        format: :text
      ).and_return(mock_streamer)

      expect(mock_streamer).to receive(:stream).and_return(5)

      exit_code = run_cli(%w[tail api worker])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)
    end
  end

  describe 'options handling' do
    it 'passes filter_pattern, since, and custom region' do
      mock_streamer = instance_double(Veltrunode::AWS::LogStreamer)
      expect(Veltrunode::AWS::LogStreamer).to receive(:new).with(
        targets: ['worker'],
        region: 'us-west-2',
        filter_pattern: 'ERROR',
        since: '10m',
        follow: false,
        format: :json
      ).and_return(mock_streamer)

      expect(mock_streamer).to receive(:stream).and_return(3)

      exit_code = run_cli(
        %w[tail worker --filter-pattern ERROR --since 10m --region us-west-2 --no-follow --format json]
      )
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)
    end

    it 'returns invalid input error when since is malformed' do
      exit_code = run_cli(%w[tail worker --since invalid_duration])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_INVALID_INPUT)
      expect(stderr.string).to include('Invalid since format')
    end
  end

  describe 'error handling' do
    it 'returns exit code 4 when AWS authorization fails' do
      mock_streamer = instance_double(Veltrunode::AWS::LogStreamer)
      allow(Veltrunode::AWS::LogStreamer).to receive(:new).and_return(mock_streamer)
      allow(mock_streamer).to receive(:stream).and_raise(
        Veltrunode::AWS::LogStreamError.new('AWS authorization failed: AccessDenied')
      )

      exit_code = run_cli(%w[tail worker])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_AWS_AUTH_FAILED)
      expect(stderr.string).to include('AWS authorization failed')
    end
  end

  describe 'help output' do
    it 'includes tail command in text help' do
      run_cli(['--help'])
      expect(stdout.string).to include('tail NAME [NAME2...]')
      expect(stdout.string).to include('--filter-pattern')
      expect(stdout.string).to include('--since')
      expect(stdout.string).to include('--follow')
    end

    it 'includes tail command in JSON help' do
      run_cli(['--help', '--format', 'json'])
      parsed = JSON.parse(stdout.string)
      command_names = parsed['data']['commands'].map { |c| c['name'] }
      expect(command_names).to include('tail NAME [NAME2...]')
    end
  end
end
