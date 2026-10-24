# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/async_invoke_config'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Model::AsyncInvokeConfig do
  describe 'initialization and validation' do
    it 'initializes with max_retries and max_age' do
      config = described_class.new(max_retries: 2, max_age: 3600)
      expect(config.max_retries).to eq(2)
      expect(config.maximum_retry_attempts).to eq(2)
      expect(config.max_age).to eq(3600)
      expect(config.maximum_event_age_in_seconds).to eq(3600)
      expect(config.qualifier).to eq('$LATEST')
      expect(config.destination_config?).to be false
    end

    it 'initializes with maximum_retry_attempts and max_age_seconds' do
      config = described_class.new(maximum_retry_attempts: 0, max_age_seconds: 60)
      expect(config.max_retries).to eq(0)
      expect(config.max_age).to eq(60)
    end

    it 'initializes with on_success and on_failure destinations' do
      config = described_class.new(
        on_success: 'arn:aws:sqs:ap-northeast-1:123456789012:success-queue',
        on_failure: 'arn:aws:sns:ap-northeast-1:123456789012:failure-topic'
      )
      expect(config.on_success).to eq('arn:aws:sqs:ap-northeast-1:123456789012:success-queue')
      expect(config.on_failure).to eq('arn:aws:sns:ap-northeast-1:123456789012:failure-topic')
      expect(config.destination_config?).to be true
    end

    it 'supports destination hash in initialization' do
      config = described_class.new(
        destination: {
          on_success: 'arn:aws:events:ap-northeast-1:123456789012:event-bus/default',
          on_failure: { ref: :failure_queue }
        }
      )
      expect(config.on_success).to eq('arn:aws:events:ap-northeast-1:123456789012:event-bus/default')
      expect(config.on_failure).to eq({ ref: :failure_queue })
      expect(config.destination_config?).to be true
    end

    it 'raises ValidationError when max_retries is less than 0' do
      expect do
        described_class.new(max_retries: -1)
      end.to raise_error(Veltrunode::ValidationError, /Maximum retry attempts must be between 0 and 2/)
    end

    it 'raises ValidationError when max_retries is greater than 2' do
      expect do
        described_class.new(max_retries: 3)
      end.to raise_error(Veltrunode::ValidationError, /Maximum retry attempts must be between 0 and 2/)
    end

    it 'raises ValidationError when max_age is less than 60' do
      expect do
        described_class.new(max_age: 59)
      end.to raise_error(Veltrunode::ValidationError, /Maximum event age must be between 60 and 21600 seconds/)
    end

    it 'raises ValidationError when max_age is greater than 21600' do
      expect do
        described_class.new(max_age: 21_601)
      end.to raise_error(Veltrunode::ValidationError, /Maximum event age must be between 60 and 21600 seconds/)
    end

    it 'raises ValidationError when no configuration is specified' do
      expect do
        described_class.new
      end.to raise_error(Veltrunode::ValidationError, /must specify at least one/)
    end
  end

  describe '.destination_type' do
    it 'detects sqs destination from ARN and hash' do
      expect(described_class.destination_type('arn:aws:sqs:ap-northeast-1:123456789012:queue')).to eq(:sqs)
      expect(described_class.destination_type({ sqs: 'my-queue' })).to eq(:sqs)
      expect(described_class.destination_type({ queue: 'my-queue' })).to eq(:sqs)
    end

    it 'detects sns destination from ARN and hash' do
      expect(described_class.destination_type('arn:aws:sns:ap-northeast-1:123456789012:topic')).to eq(:sns)
      expect(described_class.destination_type({ sns: 'my-topic' })).to eq(:sns)
      expect(described_class.destination_type({ topic: 'my-topic' })).to eq(:sns)
    end

    it 'detects event_bridge destination from ARN and hash' do
      arn = 'arn:aws:events:ap-northeast-1:123456789012:event-bus/default'
      expect(described_class.destination_type(arn)).to eq(:event_bridge)
      expect(described_class.destination_type({ events: 'default' })).to eq(:event_bridge)
      expect(described_class.destination_type({ event_bridge: 'default' })).to eq(:event_bridge)
    end

    it 'detects lambda destination from ARN and hash' do
      arn = 'arn:aws:lambda:ap-northeast-1:123456789012:function:worker'
      expect(described_class.destination_type(arn)).to eq(:lambda)
      expect(described_class.destination_type({ lambda: 'worker' })).to eq(:lambda)
      expect(described_class.destination_type({ function: 'worker' })).to eq(:lambda)
    end

    it 'returns :unknown for unidentifiable destinations' do
      expect(described_class.destination_type('unknown-target')).to eq(:unknown)
      expect(described_class.destination_type(nil)).to eq(:unknown)
    end
  end

  describe '#to_h' do
    it 'converts configuration to hash representation' do
      config = described_class.new(
        max_retries: 1,
        max_age: 1800,
        on_success: 'arn:aws:sqs:ap-northeast-1:123456789012:success',
        on_failure: 'arn:aws:sns:ap-northeast-1:123456789012:failure'
      )

      expect(config.to_h).to eq(
        'maximum_retry_attempts' => 1,
        'maximum_event_age_in_seconds' => 1800,
        'destination_config' => {
          'on_success' => 'arn:aws:sqs:ap-northeast-1:123456789012:success',
          'on_failure' => 'arn:aws:sns:ap-northeast-1:123456789012:failure'
        }
      )
    end
  end

  describe 'Function integration' do
    it 'normalizes hash into AsyncInvokeConfig instance' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        async_invoke: { max_retries: 2, max_age: 3600 }
      )

      expect(fn.async_invoke?).to be true
      expect(fn.async_invoke_enabled?).to be true
      expect(fn.async_invoke).to be_a(described_class)
      expect(fn.async_invoke.max_retries).to eq(2)
      expect(fn.async_invoke.max_age).to eq(3600)
    end

    it 'accepts nil or false as disabled async_invoke' do
      fn = Veltrunode::Model::Function.new(
        logical_name: 'api',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        async_invoke: nil
      )

      expect(fn.async_invoke?).to be false
      expect(fn.async_invoke).to be_nil

      fn_false = Veltrunode::Model::Function.new(
        logical_name: 'api2',
        handler: 'api.handler',
        runtime: 'nodejs20.x',
        async_invoke: false
      )

      expect(fn_false.async_invoke?).to be false
      expect(fn_false.async_invoke).to be_nil
    end

    it 'raises ValidationError for invalid type' do
      expect do
        Veltrunode::Model::Function.new(
          logical_name: 'api',
          handler: 'api.handler',
          runtime: 'nodejs20.x',
          async_invoke: 'invalid'
        )
      end.to raise_error(Veltrunode::ValidationError, /Invalid async_invoke configuration/)
    end
  end
end
