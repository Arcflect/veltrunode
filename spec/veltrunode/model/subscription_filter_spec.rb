# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/subscription_filter'

RSpec.describe Veltrunode::Model::SubscriptionFilter do
  describe '#initialize' do
    it 'creates a valid subscription filter with default attributes' do
      filter = described_class.new(
        destination: 'arn:aws:lambda:ap-northeast-1:123456789012:function:log-forwarder'
      )

      expect(filter.destination).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:log-forwarder')
      expect(filter.filter_pattern).to eq('')
      expect(filter.destination_type).to eq(:auto)
      expect(filter.name).to be_nil
      expect(filter.role_arn).to be_nil
      expect(filter.distribution).to be_nil
      expect(filter).to be_frozen
      expect(filter.lambda_destination?).to be true
      expect(filter.kinesis_destination?).to be false
      expect(filter.firehose_destination?).to be false
    end

    it 'infers kinesis destination from ARN' do
      filter = described_class.new(
        destination: 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/my-log-stream',
        filter_pattern: '[timestamp, request_id, level = ERROR*, ...]'
      )

      expect(filter.filter_pattern).to eq('[timestamp, request_id, level = ERROR*, ...]')
      expect(filter.kinesis_destination?).to be true
      expect(filter.lambda_destination?).to be false
      expect(filter.firehose_destination?).to be false
    end

    it 'infers firehose destination from ARN' do
      filter = described_class.new(
        destination: 'arn:aws:firehose:ap-northeast-1:123456789012:deliverystream/my-firehose-stream',
        filter_pattern: '{ $.level = "ERROR" }'
      )

      expect(filter.firehose_destination?).to be true
      expect(filter.kinesis_destination?).to be false
      expect(filter.lambda_destination?).to be false
    end

    it 'allows explicit destination_type' do
      filter = described_class.new(
        destination: 'CustomLogsDestination',
        destination_type: :kinesis,
        role_arn: 'arn:aws:iam::123456789012:role/CustomLogsRole',
        distribution: 'ByLogStream'
      )

      expect(filter.destination_type).to eq(:kinesis)
      expect(filter.kinesis_destination?).to be true
      expect(filter.role_arn).to eq('arn:aws:iam::123456789012:role/CustomLogsRole')
      expect(filter.distribution).to eq('ByLogStream')
    end

    it 'raises ValidationError when destination is missing' do
      expect do
        described_class.new(destination: nil)
      end.to raise_error(Veltrunode::ValidationError, /destination is required/i)
    end

    it 'raises ValidationError when filter_pattern is not a String' do
      expect do
        described_class.new(
          destination: 'arn:aws:lambda:ap-northeast-1:123456789012:function:log-forwarder',
          filter_pattern: 123
        )
      end.to raise_error(Veltrunode::ValidationError, /filter_pattern must be a String/)
    end

    it 'raises ValidationError when destination_type is unsupported' do
      expect do
        described_class.new(
          destination: 'arn:aws:sqs:ap-northeast-1:123456789012:log-queue',
          destination_type: :sqs
        )
      end.to raise_error(Veltrunode::ValidationError, /Unsupported destination_type/)
    end

    it 'raises ValidationError when distribution is invalid' do
      expect do
        described_class.new(
          destination: 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/stream',
          distribution: 'InvalidDistribution'
        )
      end.to raise_error(Veltrunode::ValidationError, /Invalid distribution/)
    end
  end
end
