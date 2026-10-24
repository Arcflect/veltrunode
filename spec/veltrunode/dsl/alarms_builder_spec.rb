# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/function_builder'
require 'veltrunode/dsl/application_builder'
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

    describe 'recommended preset' do
      it 'automatically deploys error_rate > 1%, throttles >= 1, and duration > 80% of timeout' do
        builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
        builder.timeout 10
        topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)

        builder.alarms :recommended, topic: topic_ref

        fn = builder.build
        expect(fn.alarms.size).to eq(3)

        error_rate_alarm = fn.alarms.find { |a| a.metric == :error_rate }
        expect(error_rate_alarm).not_to be_nil
        expect(error_rate_alarm.threshold).to eq(1)
        expect(error_rate_alarm.comparison_operator).to eq('GreaterThanThreshold')
        expect(error_rate_alarm.alarm_actions).to eq([topic_ref])

        throttles_alarm = fn.alarms.find { |a| a.metric == :throttles }
        expect(throttles_alarm).not_to be_nil
        expect(throttles_alarm.threshold).to eq(1)
        expect(throttles_alarm.comparison_operator).to eq('GreaterThanOrEqualToThreshold')
        expect(throttles_alarm.alarm_actions).to eq([topic_ref])

        duration_alarm = fn.alarms.find { |a| a.metric == :duration }
        expect(duration_alarm).not_to be_nil
        # 10s * 1000 * 0.8 = 8000ms
        expect(duration_alarm.threshold).to eq(8000)
        expect(duration_alarm.comparison_operator).to eq('GreaterThanThreshold')
        expect(duration_alarm.alarm_actions).to eq([topic_ref])
      end

      it 'supports threshold overrides via block' do
        builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
        builder.timeout 5

        builder.alarms :recommended do
          error_rate 5
          duration 3000
        end

        fn = builder.build
        expect(fn.alarms.size).to eq(3)

        error_rate_alarm = fn.alarms.find { |a| a.metric == :error_rate }
        expect(error_rate_alarm.threshold).to eq(5)

        duration_alarm = fn.alarms.find { |a| a.metric == :duration }
        expect(duration_alarm.threshold).to eq(3000)

        throttles_alarm = fn.alarms.find { |a| a.metric == :throttles }
        expect(throttles_alarm.threshold).to eq(1)
      end

      it 'supports threshold overrides via hash options' do
        builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
        builder.alarms preset: :recommended, error_rate: 2

        fn = builder.build
        expect(fn.alarms.size).to eq(3)

        error_rate_alarm = fn.alarms.find { |a| a.metric == :error_rate }
        expect(error_rate_alarm.threshold).to eq(2)
      end

      it 'raises ValidationError with VLT-ALARM-002 for unknown preset' do
        builder = Veltrunode::DSL::FunctionBuilder.new(:worker)

        expect do
          builder.alarms preset: :super_strict
        end.to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics.first.code).to eq('VLT-ALARM-002')
        }
      end

      it 'allows opt-out with alarms false' do
        builder = Veltrunode::DSL::FunctionBuilder.new(:worker, alarms_default: :recommended)
        builder.alarms false

        fn = builder.build
        expect(fn.alarms).to be_empty
      end

      it 'supports alarms: :recommended via function keyword argument' do
        app_builder = Veltrunode::DSL::ApplicationBuilder.new('my-app')
        app_builder.function :worker, alarms: :recommended do
          timeout 5
        end

        app = app_builder.build
        worker = app.functions.find { |f| f.logical_name == 'worker' }
        expect(worker.alarms.size).to eq(3)
        expect(worker.alarms.find { |a| a.metric == :error_rate }.threshold).to eq(1)
        expect(worker.alarms.find { |a| a.metric == :duration }.threshold).to eq(4000)
      end
    end

    describe 'ApplicationBuilder integration' do
      it 'inherits default recommended alarm preset and supports function-level opt-out' do
        app_builder = Veltrunode::DSL::ApplicationBuilder.new('my-app')
        topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)

        app_builder.defaults do
          alarms :recommended, topic: topic_ref
        end

        app_builder.function :worker do
          timeout 5
        end

        app_builder.function :no_alarm_worker do
          alarms false
        end

        app_builder.function :custom_worker do
          timeout 5
          alarms do
            error_rate 3
          end
        end

        app = app_builder.build
        worker = app.functions.find { |f| f.logical_name == 'worker' }
        expect(worker.alarms.size).to eq(3)
        expect(worker.alarms.find { |a| a.metric == :error_rate }.threshold).to eq(1)
        expect(worker.alarms.find { |a| a.metric == :duration }.threshold).to eq(4000)

        no_alarm = app.functions.find { |f| f.logical_name == 'no_alarm_worker' }
        expect(no_alarm.alarms).to be_empty

        custom = app.functions.find { |f| f.logical_name == 'custom_worker' }
        expect(custom.alarms.size).to eq(3)
        expect(custom.alarms.find { |a| a.metric == :error_rate }.threshold).to eq(3)
        expect(custom.alarms.find { |a| a.metric == :duration }.threshold).to eq(4000)
      end
    end
  end
end
