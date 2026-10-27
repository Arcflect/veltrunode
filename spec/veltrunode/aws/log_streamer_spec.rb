# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/aws/log_streamer'

RSpec.describe Veltrunode::AWS::LogStreamer do
  let(:mock_logs_client) { instance_double('Aws::CloudWatchLogs::Client') }
  let(:output) { StringIO.new }

  # Test stubs instead of OpenStruct
  let(:log_event_stub) do
    Struct.new(:event_id, :timestamp, :message, :ingestion_time, keyword_init: true)
  end

  let(:log_response_stub) do
    Struct.new(:events, :next_token, keyword_init: true)
  end

  describe Veltrunode::AWS::LogEvent do
    describe '.infer_function_name' do
      it 'extracts function name from standard Lambda log group' do
        expect(described_class.infer_function_name('/aws/lambda/my-func')).to eq('my-func')
      end

      it 'returns log group name as is if not standard Lambda path' do
        expect(described_class.infer_function_name('/custom/app/logs')).to eq('/custom/app/logs')
      end
    end

    describe '#iso_timestamp' do
      it 'formats timestamp in UTC ISO-like format' do
        event = described_class.new(
          event_id: 'ev-1',
          timestamp: 1_700_000_000_000,
          message: 'Hello world',
          log_group_name: '/aws/lambda/test'
        )
        expect(event.iso_timestamp).to eq('2023-11-14 22:13:20 UTC')
      end
    end

    describe '#to_h and #to_json' do
      it 'returns structured hash and json' do
        event = described_class.new(
          event_id: 'ev-1',
          timestamp: 1_700_000_000_000,
          message: "Hello world\n",
          log_group_name: '/aws/lambda/test',
          function_name: 'test'
        )
        hash = event.to_h
        expect(hash['event_id']).to eq('ev-1')
        expect(hash['timestamp']).to eq(1_700_000_000_000)
        expect(hash['function_name']).to eq('test')
        expect(hash['log_group_name']).to eq('/aws/lambda/test')
        expect(hash['message']).to eq("Hello world\n")

        parsed = JSON.parse(event.to_json)
        expect(parsed['event_id']).to eq('ev-1')
      end
    end
  end

  describe '.parse_since_duration' do
    it 'parses seconds integer and string' do
      expect(described_class.parse_since_duration(120)).to eq(120)
      expect(described_class.parse_since_duration('120')).to eq(120)
      expect(described_class.parse_since_duration('30s')).to eq(30)
      expect(described_class.parse_since_duration('45sec')).to eq(45)
    end

    it 'parses minutes' do
      expect(described_class.parse_since_duration('5m')).to eq(300)
      expect(described_class.parse_since_duration('10min')).to eq(600)
    end

    it 'parses hours' do
      expect(described_class.parse_since_duration('1h')).to eq(3600)
      expect(described_class.parse_since_duration('2hours')).to eq(7200)
    end

    it 'parses days' do
      expect(described_class.parse_since_duration('1d')).to eq(86_400)
    end

    it 'returns default for nil or empty' do
      expect(described_class.parse_since_duration(nil)).to eq(300)
      expect(described_class.parse_since_duration('')).to eq(300)
    end

    it 'raises ArgumentError on invalid format' do
      expect { described_class.parse_since_duration('invalid') }.to raise_error(ArgumentError, /Invalid since format/)
    end
  end

  describe '#initialize' do
    it 'normalizes plain function names to /aws/lambda/<name>' do
      streamer = described_class.new(targets: 'worker', client: mock_logs_client)
      expect(streamer.targets).to eq([{ log_group_name: '/aws/lambda/worker', function_name: 'worker' }])
      expect(streamer.prefix_function_name).to be false
    end

    it 'preserves already formatted log group paths' do
      streamer = described_class.new(targets: '/aws/lambda/custom', client: mock_logs_client)
      expect(streamer.targets).to eq([{ log_group_name: '/aws/lambda/custom', function_name: 'custom' }])
    end

    it 'enables prefix_function_name automatically for multiple targets' do
      streamer = described_class.new(targets: %w[api worker], client: mock_logs_client)
      expect(streamer.targets.size).to eq(2)
      expect(streamer.prefix_function_name).to be true
    end

    it 'raises ArgumentError when targets is empty' do
      expect { described_class.new(targets: [], client: mock_logs_client) }
        .to raise_error(ArgumentError, /At least one target/)
    end
  end

  describe '#fetch_batch' do
    let(:streamer) do
      described_class.new(
        targets: 'worker',
        client: mock_logs_client,
        filter_pattern: 'ERROR',
        since: 60,
        output: output
      )
    end

    it 'calls filter_log_events with log_group_name, start_time, and filter_pattern' do
      response = log_response_stub.new(
        events: [
          log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'ERROR: something broke'),
          log_event_stub.new(event_id: 'ev-2', timestamp: 1_700_000_001_000, message: 'ERROR: another break')
        ],
        next_token: nil
      )

      expect(mock_logs_client).to receive(:filter_log_events).with(
        hash_including(
          log_group_name: '/aws/lambda/worker',
          filter_pattern: 'ERROR'
        )
      ).and_return(response)

      events = streamer.fetch_batch
      expect(events.size).to eq(2)
      expect(events[0].event_id).to eq('ev-1')
      expect(events[0].message).to eq('ERROR: something broke')
      expect(events[1].event_id).to eq('ev-2')
    end

    it 'deduplicates events across consecutive batches' do
      resp1 = log_response_stub.new(
        events: [
          log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'log 1')
        ],
        next_token: nil
      )
      resp2 = log_response_stub.new(
        events: [
          log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'log 1'),
          log_event_stub.new(event_id: 'ev-2', timestamp: 1_700_000_002_000, message: 'log 2')
        ],
        next_token: nil
      )

      allow(mock_logs_client).to receive(:filter_log_events).and_return(resp1, resp2)

      batch1 = streamer.fetch_batch
      expect(batch1.map(&:event_id)).to eq(['ev-1'])

      batch2 = streamer.fetch_batch
      expect(batch2.map(&:event_id)).to eq(['ev-2'])
    end

    it 'handles pagination via next_token' do
      resp1 = log_response_stub.new(
        events: [log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'page 1')],
        next_token: 'token-abc'
      )
      resp2 = log_response_stub.new(
        events: [log_event_stub.new(event_id: 'ev-2', timestamp: 1_700_000_001_000, message: 'page 2')],
        next_token: nil
      )

      expect(mock_logs_client).to receive(:filter_log_events).with(
        hash_including(log_group_name: '/aws/lambda/worker')
      ).and_return(resp1)

      expect(mock_logs_client).to receive(:filter_log_events).with(
        hash_including(log_group_name: '/aws/lambda/worker', next_token: 'token-abc')
      ).and_return(resp2)

      events = streamer.fetch_batch
      expect(events.map(&:event_id)).to eq(%w[ev-1 ev-2])
    end
  end

  describe 'multiple function tailing and ordering' do
    let(:multi_streamer) do
      described_class.new(
        targets: %w[api worker],
        client: mock_logs_client,
        output: output
      )
    end

    it 'fetches from all log groups and sorts events by timestamp' do
      api_resp = log_response_stub.new(
        events: [
          log_event_stub.new(event_id: 'api-1', timestamp: 1_700_000_000_000, message: 'api request received'),
          log_event_stub.new(event_id: 'api-2', timestamp: 1_700_000_004_000, message: 'api response sent')
        ],
        next_token: nil
      )
      worker_resp = log_response_stub.new(
        events: [
          log_event_stub.new(event_id: 'wrk-1', timestamp: 1_700_000_002_000, message: 'worker processing')
        ],
        next_token: nil
      )

      allow(mock_logs_client).to receive(:filter_log_events).with(
        hash_including(log_group_name: '/aws/lambda/api')
      ).and_return(api_resp)

      allow(mock_logs_client).to receive(:filter_log_events).with(
        hash_including(log_group_name: '/aws/lambda/worker')
      ).and_return(worker_resp)

      events = multi_streamer.fetch_batch
      expect(events.map(&:event_id)).to eq(%w[api-1 wrk-1 api-2])
      expect(events.map(&:function_name)).to eq(%w[api worker api])
    end
  end

  describe '#stream' do
    context 'when follow is false' do
      it 'runs a single batch and prints text output without loop' do
        streamer = described_class.new(
          targets: 'worker',
          client: mock_logs_client,
          follow: false,
          output: output
        )

        resp = log_response_stub.new(
          events: [
            log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'Processed event 1')
          ],
          next_token: nil
        )
        allow(mock_logs_client).to receive(:filter_log_events).and_return(resp)

        count = streamer.stream
        expect(count).to eq(1)
        expect(output.string).to include('[2023-11-14 22:13:20 UTC] Processed event 1')
      end

      it 'outputs json format when format is :json' do
        streamer = described_class.new(
          targets: 'worker',
          client: mock_logs_client,
          follow: false,
          format: :json,
          output: output
        )

        resp = log_response_stub.new(
          events: [
            log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'Processed event 1')
          ],
          next_token: nil
        )
        allow(mock_logs_client).to receive(:filter_log_events).and_return(resp)

        streamer.stream
        parsed = JSON.parse(output.string.lines.first)
        expect(parsed['function_name']).to eq('worker')
        expect(parsed['message']).to eq('Processed event 1')
      end

      it 'includes function name prefix in text output when multiple targets' do
        streamer = described_class.new(
          targets: %w[api worker],
          client: mock_logs_client,
          follow: false,
          output: output
        )

        resp = log_response_stub.new(
          events: [
            log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'Multi log message')
          ],
          next_token: nil
        )
        empty_resp = log_response_stub.new(events: [])
        allow(mock_logs_client).to receive(:filter_log_events).and_return(resp, empty_resp)

        streamer.stream
        expect(output.string).to include('[api] Multi log message')
      end
    end

    context 'when stopped before or during streaming' do
      it 'exits loop when stop! is called before streaming' do
        streamer = described_class.new(
          targets: 'worker',
          client: mock_logs_client,
          follow: true,
          output: output
        )
        streamer.stop!

        count = streamer.stream
        expect(count).to eq(0)
        expect(streamer.stopped?).to be true
      end

      it 'exits loop when stop! is called inside stream block' do
        streamer = described_class.new(
          targets: 'worker',
          client: mock_logs_client,
          follow: true,
          poll_interval: 0.001,
          output: output
        )

        resp = log_response_stub.new(
          events: [
            log_event_stub.new(event_id: 'ev-1', timestamp: 1_700_000_000_000, message: 'Stop test event')
          ],
          next_token: nil
        )
        allow(mock_logs_client).to receive(:filter_log_events).and_return(resp)

        processed = 0
        streamer.stream do |_event|
          processed += 1
          streamer.stop!
        end

        expect(processed).to eq(1)
        expect(streamer.stopped?).to be true
      end
    end
  end

  describe 'error handling' do
    it 'warns once and ignores ResourceNotFoundException without terminating' do
      streamer = described_class.new(
        targets: 'worker',
        client: mock_logs_client,
        follow: false,
        output: output
      )

      err = StandardError.new('The specified log group does not exist. (ResourceNotFoundException)')
      allow(mock_logs_client).to receive(:filter_log_events).and_raise(err)

      count = streamer.stream
      expect(count).to eq(0)
      expect(output.string).to include("[WARN] Log group '/aws/lambda/worker' does not exist yet.")
    end

    it 'raises LogStreamError when authorization fails' do
      streamer = described_class.new(
        targets: 'worker',
        client: mock_logs_client,
        follow: false,
        output: output
      )

      err = Class.new(StandardError) do
        def self.name
          'Aws::CloudWatchLogs::Errors::AccessDeniedException'
        end
      end.new('User is not authorized')

      allow(mock_logs_client).to receive(:filter_log_events).and_raise(err)

      expect { streamer.stream }.to raise_error(Veltrunode::AWS::LogStreamError, /AWS authorization failed/)
    end
  end
end
