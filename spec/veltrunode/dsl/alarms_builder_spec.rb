# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/function_builder'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::DSL::AlarmsBuilder do
  describe 'DSL evaluation in FunctionBuilder' do
    it 'builds alarms with block syntax and default topic' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
      topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)

      builder.alarms do
        topic topic_ref
        errors threshold: 1, period: 60
        duration threshold: 3000, statistic: 'Average'
        throttles threshold: 2
      end

      fn = builder.build
      expect(fn.alarms.size).to eq(3)

      errors_alarm = fn.alarms.find { |a| a.metric == :errors }
      expect(errors_alarm).not_to be_nil
      expect(errors_alarm.threshold).to eq(1)
      expect(errors_alarm.period).to eq(60)
      expect(errors_alarm.alarm_actions).to eq([topic_ref])

      duration_alarm = fn.alarms.find { |a| a.metric == :duration }
      expect(duration_alarm).not_to be_nil
      expect(duration_alarm.threshold).to eq(3000)
      expect(duration_alarm.statistic).to eq('Average')
      expect(duration_alarm.alarm_actions).to eq([topic_ref])

      throttles_alarm = fn.alarms.find { |a| a.metric == :throttles }
      expect(throttles_alarm).not_to be_nil
      expect(throttles_alarm.threshold).to eq(2)
      expect(throttles_alarm.alarm_actions).to eq([topic_ref])
    end

    it 'allows overriding topic per alarm' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
      default_topic = Veltrunode::DSL::Reference.new(:general_alerts)
      critical_topic = Veltrunode::DSL::Reference.new(:critical_alerts)

      builder.alarms topic: default_topic do
        errors threshold: 1, topic: critical_topic
        duration threshold: 5000
      end

      fn = builder.build
      errors_alarm = fn.alarms.find { |a| a.metric == :errors }
      duration_alarm = fn.alarms.find { |a| a.metric == :duration }

      expect(errors_alarm.alarm_actions).to eq([critical_topic])
      expect(duration_alarm.alarm_actions).to eq([default_topic])
    end

    it 'builds alarms with hash options syntax' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
      topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)

      builder.alarms(
        topic: topic_ref,
        errors: { threshold: 2 },
        duration: { threshold: 4000 }
      )

      fn = builder.build
      expect(fn.alarms.size).to eq(2)
      expect(fn.alarms.map(&:metric)).to contain_exactly(:errors, :duration)
    end
  end
end
