# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/alarm'

RSpec.describe Veltrunode::Model::Alarm do
  describe '#initialize' do
    it 'creates a valid errors alarm with default attributes' do
      alarm = described_class.new(
        metric: :errors,
        threshold: 1
      )

      expect(alarm.metric).to eq(:errors)
      expect(alarm.threshold).to eq(1)
      expect(alarm.evaluation_periods).to eq(1)
      expect(alarm.period).to eq(60)
      expect(alarm.statistic).to eq('Sum')
      expect(alarm.comparison_operator).to eq('GreaterThanOrEqualToThreshold')
      expect(alarm.treat_missing_data).to eq('notBreaching')
      expect(alarm.alarm_actions).to be_empty
      expect(alarm).to be_frozen
    end

    it 'creates a valid duration alarm with default Average statistic' do
      alarm = described_class.new(
        metric: :duration,
        threshold: 3000
      )

      expect(alarm.metric).to eq(:duration)
      expect(alarm.threshold).to eq(3000)
      expect(alarm.statistic).to eq('Average')
    end

    it 'creates a valid throttles alarm' do
      alarm = described_class.new(
        metric: :throttles,
        threshold: 5,
        period: 300,
        evaluation_periods: 2,
        alarm_actions: ['arn:aws:sns:ap-northeast-1:123456789012:alerts']
      )

      expect(alarm.metric).to eq(:throttles)
      expect(alarm.threshold).to eq(5)
      expect(alarm.period).to eq(300)
      expect(alarm.evaluation_periods).to eq(2)
      expect(alarm.alarm_actions).to eq(['arn:aws:sns:ap-northeast-1:123456789012:alerts'])
    end

    it 'raises ValidationError when metric is unsupported' do
      expect do
        described_class.new(metric: :unknown_metric, threshold: 1)
      end.to raise_error(Veltrunode::ValidationError, /Unsupported alarm metric/)
    end

    it 'raises ValidationError when threshold is missing or invalid' do
      expect do
        described_class.new(metric: :errors, threshold: nil)
      end.to raise_error(Veltrunode::ValidationError, /Threshold is required/)

      expect do
        described_class.new(metric: :errors, threshold: -1)
      end.to raise_error(Veltrunode::ValidationError, /non-negative number/)
    end

    it 'raises ValidationError when evaluation_periods is less than 1' do
      expect do
        described_class.new(metric: :errors, threshold: 1, evaluation_periods: 0)
      end.to raise_error(Veltrunode::ValidationError, /evaluation_periods must be at least 1/)
    end

    it 'raises ValidationError when period is invalid' do
      expect do
        described_class.new(metric: :errors, threshold: 1, period: 25)
      end.to raise_error(Veltrunode::ValidationError, /multiple of 10 seconds/)
    end
  end
end
