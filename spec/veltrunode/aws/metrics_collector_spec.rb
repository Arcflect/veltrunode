# frozen_string_literal: true

require 'spec_helper'
require 'time'
require 'json'
require 'veltrunode/aws/metrics_collector'

RSpec.describe Veltrunode::AWS::MetricsCollector do
  let(:mock_cw_client) { instance_double('Aws::CloudWatch::Client') }
  let(:fixed_now) { Time.utc(2026, 10, 28, 12, 0, 0) }

  # Test stub for metric results avoiding Struct#values override
  let(:metric_result_class) do
    Class.new do
      attr_reader :id, :values

      def initialize(id:, values:)
        @id = id
        @values = values
      end
    end
  end

  let(:metric_data_response_class) do
    Class.new do
      attr_reader :metric_data_results

      def initialize(metric_data_results:)
        @metric_data_results = metric_data_results
      end
    end
  end

  describe Veltrunode::AWS::FunctionMetrics do
    describe '#calculate_error_rate' do
      it 'calculates percentage when invocations and errors are present' do
        metrics = described_class.new(
          function_name: 'api',
          period: '24h',
          start_time: fixed_now - 86_400,
          end_time: fixed_now,
          invocations: 1000,
          errors: 15,
          throttles: 2,
          duration_p50: 45.2,
          duration_p95: 120.5,
          duration_p99: 340.1
        )
        expect(metrics.error_rate).to eq(1.5)
      end

      it 'returns 0.0 when invocations is zero' do
        metrics = described_class.new(
          function_name: 'api',
          period: '24h',
          start_time: fixed_now - 86_400,
          end_time: fixed_now,
          invocations: 0,
          errors: 0
        )
        expect(metrics.error_rate).to eq(0.0)
      end
    end

    describe '#to_h and #to_json' do
      it 'converts to structured hash and json' do
        metrics = described_class.new(
          function_name: 'worker',
          period: '1h',
          start_time: fixed_now - 3600,
          end_time: fixed_now,
          invocations: 50,
          errors: 1,
          throttles: 0,
          duration_p50: 100.0,
          duration_p95: 250.0,
          duration_p99: 500.0
        )
        hash = metrics.to_h
        expect(hash['function_name']).to eq('worker')
        expect(hash['period']).to eq('1h')
        expect(hash['invocations']).to eq(50)
        expect(hash['errors']).to eq(1)
        expect(hash['error_rate']).to eq(2.0)
        expect(hash['throttles']).to eq(0)
        expect(hash['duration']).to eq({ 'p50' => 100.0, 'p95' => 250.0, 'p99' => 500.0 })

        parsed = JSON.parse(metrics.to_json)
        expect(parsed['function_name']).to eq('worker')
        expect(parsed['duration']['p95']).to eq(250.0)
      end
    end
  end

  describe '.parse_period_duration' do
    it 'parses hours, days, and seconds' do
      expect(described_class.parse_period_duration('1h')).to eq(3600)
      expect(described_class.parse_period_duration('24h')).to eq(86_400)
      expect(described_class.parse_period_duration('7d')).to eq(604_800)
      expect(described_class.parse_period_duration('300')).to eq(300)
    end

    it 'returns 86400 (24h) for nil or empty string' do
      expect(described_class.parse_period_duration(nil)).to eq(86_400)
      expect(described_class.parse_period_duration('')).to eq(86_400)
    end

    it 'raises ArgumentError on invalid format' do
      expect { described_class.parse_period_duration('unknown') }.to raise_error(ArgumentError, /Invalid period format/)
    end
  end

  describe '#collect' do
    let(:collector) do
      described_class.new(client: mock_cw_client, region: 'ap-northeast-1', period: '24h')
    end

    it 'queries CloudWatch for Invocations, Errors, Throttles, and Duration percentiles' do
      response = metric_data_response_class.new(
        metric_data_results: [
          metric_result_class.new(id: 'invocations', values: [1200.0]),
          metric_result_class.new(id: 'errors', values: [6.0]),
          metric_result_class.new(id: 'throttles', values: [1.0]),
          metric_result_class.new(id: 'duration_p50', values: [55.4]),
          metric_result_class.new(id: 'duration_p95', values: [180.2]),
          metric_result_class.new(id: 'duration_p99', values: [420.8])
        ]
      )

      expect(mock_cw_client).to receive(:get_metric_data).with(
        hash_including(
          start_time: fixed_now - 86_400,
          end_time: fixed_now,
          metric_data_queries: array_including(
            hash_including(id: 'invocations'),
            hash_including(id: 'errors'),
            hash_including(id: 'throttles'),
            hash_including(id: 'duration_p50'),
            hash_including(id: 'duration_p95'),
            hash_including(id: 'duration_p99')
          )
        )
      ).and_return(response)

      result = collector.collect('my-func', now: fixed_now)
      expect(result.function_name).to eq('my-func')
      expect(result.invocations).to eq(1200)
      expect(result.errors).to eq(6)
      expect(result.error_rate).to eq(0.5)
      expect(result.throttles).to eq(1)
      expect(result.duration_p50).to eq(55.4)
      expect(result.duration_p95).to eq(180.2)
      expect(result.duration_p99).to eq(420.8)
    end

    it 'handles empty metric responses safely' do
      response = metric_data_response_class.new(metric_data_results: [])
      allow(mock_cw_client).to receive(:get_metric_data).and_return(response)

      result = collector.collect('unused-func', now: fixed_now)
      expect(result.invocations).to eq(0)
      expect(result.errors).to eq(0)
      expect(result.error_rate).to eq(0.0)
      expect(result.throttles).to eq(0)
      expect(result.duration_p50).to be_nil
      expect(result.duration_p95).to be_nil
      expect(result.duration_p99).to be_nil
    end
  end

  describe '#collect_all' do
    let(:collector) { described_class.new(client: mock_cw_client, period: '1h') }

    it 'collects metrics for multiple functions' do
      allow(mock_cw_client).to receive(:get_metric_data).and_return(
        metric_data_response_class.new(
          metric_data_results: [metric_result_class.new(id: 'invocations', values: [10.0])]
        ),
        metric_data_response_class.new(
          metric_data_results: [metric_result_class.new(id: 'invocations', values: [20.0])]
        )
      )

      results = collector.collect_all(%w[fn1 fn2], now: fixed_now)
      expect(results.size).to eq(2)
      expect(results[0].function_name).to eq('fn1')
      expect(results[0].invocations).to eq(10)
      expect(results[1].function_name).to eq('fn2')
      expect(results[1].invocations).to eq(20)
    end
  end

  describe 'error handling' do
    let(:collector) { described_class.new(client: mock_cw_client) }

    it 'raises MetricsError when authorization fails' do
      auth_err = Class.new(StandardError) do
        def self.name
          'Aws::CloudWatch::Errors::AccessDeniedException'
        end
      end.new('Access Denied')

      allow(mock_cw_client).to receive(:get_metric_data).and_raise(auth_err)

      expect { collector.collect('my-func') }.to raise_error(
        Veltrunode::AWS::MetricsError,
        /AWS authorization failed/
      )
    end
  end
end
