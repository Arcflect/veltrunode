# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'time'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/metrics_collector'

RSpec.describe 'CLI veltrunode metrics' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:fixed_now) { Time.utc(2026, 10, 28, 12, 0, 0) }

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
      name: 'metrics-test-app',
      region: 'ap-northeast-1',
      stage: 'production',
      functions: [worker_func, api_func]
    )
  end

  let(:worker_metrics) do
    Veltrunode::AWS::FunctionMetrics.new(
      function_name: 'worker',
      period: '24h',
      start_time: fixed_now - 86_400,
      end_time: fixed_now,
      invocations: 850,
      errors: 0,
      throttles: 0,
      duration_p50: 180.0,
      duration_p95: 450.2,
      duration_p99: 890.0
    )
  end

  let(:api_metrics) do
    Veltrunode::AWS::FunctionMetrics.new(
      function_name: 'api',
      period: '24h',
      start_time: fixed_now - 86_400,
      end_time: fixed_now,
      invocations: 1420,
      errors: 3,
      throttles: 1,
      duration_p50: 45.2,
      duration_p95: 120.5,
      duration_p99: 340.1
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

  describe 'all functions metrics collection (default)' do
    it 'collects metrics for all functions in application and prints table' do
      mock_collector = instance_double(Veltrunode::AWS::MetricsCollector, region: 'ap-northeast-1')
      expect(Veltrunode::AWS::MetricsCollector).to receive(:new).with(
        region: 'ap-northeast-1',
        period: '24h'
      ).and_return(mock_collector)

      expect(mock_collector).to receive(:collect_all).with(%w[worker api]).and_return([worker_metrics, api_metrics])

      exit_code = run_cli(['metrics'])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)

      out = stdout.string
      expect(out).to include('Veltrunode Lambda Metrics (Period: 24h, Region: ap-northeast-1)')
      expect(out).to include('worker')
      expect(out).to include('850')
      expect(out).to include('180.0 ms')
      expect(out).to include('api')
      expect(out).to include('1,420')
      expect(out).to include('0.21%')
    end
  end

  describe 'single function metrics collection' do
    it 'collects metrics for specified function only' do
      mock_collector = instance_double(Veltrunode::AWS::MetricsCollector, region: 'ap-northeast-1')
      expect(Veltrunode::AWS::MetricsCollector).to receive(:new).with(
        region: 'ap-northeast-1',
        period: '24h'
      ).and_return(mock_collector)

      expect(mock_collector).to receive(:collect_all).with(['worker']).and_return([worker_metrics])

      exit_code = run_cli(%w[metrics worker])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)

      out = stdout.string
      expect(out).to include('worker')
      expect(out).not_to include('api')
    end
  end

  describe 'options handling' do
    it 'supports --period and custom --region' do
      mock_collector = instance_double(Veltrunode::AWS::MetricsCollector, region: 'us-west-2')
      expect(Veltrunode::AWS::MetricsCollector).to receive(:new).with(
        region: 'us-west-2',
        period: '1h'
      ).and_return(mock_collector)

      expect(mock_collector).to receive(:collect_all).with(['worker']).and_return([worker_metrics])

      exit_code = run_cli(%w[metrics worker --period 1h --region us-west-2])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)
    end

    it 'returns invalid input error when --period is invalid' do
      exit_code = run_cli(%w[metrics worker --period bad_period])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_INVALID_INPUT)
      expect(stderr.string).to include('Invalid period format')
    end
  end

  describe 'JSON output (--format json)' do
    it 'outputs metrics structured JSON matching schema' do
      mock_collector = instance_double(Veltrunode::AWS::MetricsCollector, region: 'ap-northeast-1')
      allow(Veltrunode::AWS::MetricsCollector).to receive(:new).and_return(mock_collector)
      allow(mock_collector).to receive(:collect_all).and_return([api_metrics])

      exit_code = run_cli(%w[metrics api --format json])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_SUCCESS)

      parsed = JSON.parse(stdout.string)
      expect(parsed['command']).to eq('metrics')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['period']).to eq('24h')
      expect(parsed['data']['region']).to eq('ap-northeast-1')

      fns = parsed['data']['functions']
      expect(fns.size).to eq(1)
      expect(fns[0]['function_name']).to eq('api')
      expect(fns[0]['invocations']).to eq(1420)
      expect(fns[0]['errors']).to eq(3)
      expect(fns[0]['error_rate']).to eq(0.21)
      expect(fns[0]['duration']['p50']).to eq(45.2)
    end
  end

  describe 'error handling' do
    it 'returns exit code 2 when no function specified and no Veltrunodefile' do
      allow(Veltrunode::SettingsLoader).to receive(:load).and_raise(StandardError.new('File not found'))

      exit_code = run_cli(['metrics'])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_INVALID_INPUT)
      expect(stderr.string).to include('Function name is required when Veltrunodefile is not found')
    end

    it 'returns exit code 4 when AWS authorization fails' do
      mock_collector = instance_double(Veltrunode::AWS::MetricsCollector, region: 'ap-northeast-1')
      allow(Veltrunode::AWS::MetricsCollector).to receive(:new).and_return(mock_collector)
      allow(mock_collector).to receive(:collect_all).and_raise(
        Veltrunode::AWS::MetricsError.new('AWS authorization failed: AccessDenied')
      )

      exit_code = run_cli(%w[metrics worker])
      expect(exit_code).to eq(Veltrunode::CLI::EXIT_AWS_AUTH_FAILED)
      expect(stderr.string).to include('AWS authorization failed')
    end
  end

  describe 'help output' do
    it 'includes metrics command and --period in help output' do
      run_cli(['--help'])
      expect(stdout.string).to include('metrics [NAME]')
      expect(stdout.string).to include('--period')
    end

    it 'includes metrics command in JSON help' do
      run_cli(['--help', '--format', 'json'])
      parsed = JSON.parse(stdout.string)
      names = parsed['data']['commands'].map { |c| c['name'] }
      expect(names).to include('metrics [NAME]')
    end
  end
end
