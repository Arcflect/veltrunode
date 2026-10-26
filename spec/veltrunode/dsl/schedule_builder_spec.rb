# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/schedule_builder'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::DSL::ScheduleBuilder do
  describe '#dlq and #dead_letter_queue' do
    let(:builder) do
      b = described_class.new(:nightly)
      b.target :convert
      b.cron '0 1 * * ? *'
      b
    end

    it 'supports string ARN format without alarm' do
      arn = 'arn:aws:sqs:ap-northeast-1:123456789012:my-queue'
      builder.dead_letter_queue arn: arn

      schedule = builder.build
      expect(schedule.dlq).to eq(arn)
      expect(schedule.dlq_arn).to eq(arn)
      expect(schedule.dlq_alarm?).to be false
    end

    it 'supports simple queue name format without alarm' do
      builder.dlq :nightly_dlq

      schedule = builder.build
      expect(schedule.dlq).to eq('nightly_dlq')
      expect(schedule.dlq_name).to eq('nightly_dlq')
      expect(schedule.dlq_alarm?).to be false
    end

    it 'supports queue name with alarm: true' do
      builder.dlq :nightly_dlq, alarm: true

      schedule = builder.build
      expect(schedule.dlq_name).to eq('nightly_dlq')
      expect(schedule.dlq_alarm?).to be true
      expect(schedule.dlq_alarm_topic).to be_nil
    end

    it 'supports queue name with alarm: true and topic' do
      topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)
      builder.dead_letter_queue :nightly_dlq, alarm: true, topic: topic_ref

      schedule = builder.build
      expect(schedule.dlq_name).to eq('nightly_dlq')
      expect(schedule.dlq_alarm?).to be true
      expect(schedule.dlq_alarm_topic).to eq(topic_ref)
    end

    it 'infers default dlq name when only alarm: true is provided' do
      builder.dlq alarm: true

      schedule = builder.build
      expect(schedule.dlq_name).to eq('nightly_dlq')
      expect(schedule.dlq_alarm?).to be true
    end

    it 'supports block DSL syntax' do
      topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)

      builder.dlq :sync_dlq do
        alarm true
        topic topic_ref
      end

      schedule = builder.build
      expect(schedule.dlq_name).to eq('sync_dlq')
      expect(schedule.dlq_alarm?).to be true
      expect(schedule.dlq_alarm_topic).to eq(topic_ref)
    end
  end
end
