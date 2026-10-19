# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/compiler/cloudformation/alarm_compiler'
require 'veltrunode/model/function'
require 'veltrunode/model/alarm'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Compiler::CloudFormation::AlarmCompiler do
  let(:fn) do
    Veltrunode::Model::Function.new(
      :converter,
      handler: 'handler.handle',
      runtime: 'ruby3.4'
    )
  end

  describe '.compile' do
    it 'compiles an errors alarm to AWS::CloudWatch::Alarm resource definition' do
      alarm = Veltrunode::Model::Alarm.new(
        metric: :errors,
        threshold: 1,
        evaluation_periods: 1,
        period: 60,
        alarm_actions: [Veltrunode::DSL::Reference.new(:alert_topic)]
      )

      res = described_class.compile(fn, alarm)
      expect(res.keys).to eq(['ConverterFunctionErrorsAlarm'])

      alarm_def = res['ConverterFunctionErrorsAlarm']
      expect(alarm_def['Type']).to eq('AWS::CloudWatch::Alarm')

      props = alarm_def['Properties']
      expect(props['Namespace']).to eq('AWS/Lambda')
      expect(props['MetricName']).to eq('Errors')
      expect(props['Dimensions']).to eq([{ 'Name' => 'FunctionName', 'Value' => { 'Ref' => 'ConverterFunction' } }])
      expect(props['Statistic']).to eq('Sum')
      expect(props['ComparisonOperator']).to eq('GreaterThanOrEqualToThreshold')
      expect(props['Threshold']).to eq(1)
      expect(props['EvaluationPeriods']).to eq(1)
      expect(props['Period']).to eq(60)
      expect(props['TreatMissingData']).to eq('notBreaching')
      expect(props['AlarmActions']).to eq([{ 'Ref' => 'AlertTopic' }])
    end

    it 'compiles a duration alarm with literal ARN action' do
      arn = 'arn:aws:sns:ap-northeast-1:123456789012:my-topic'
      alarm = Veltrunode::Model::Alarm.new(
        metric: :duration,
        threshold: 5000,
        statistic: 'Average',
        alarm_actions: [arn]
      )

      res = described_class.compile(fn, alarm)
      expect(res.keys).to eq(['ConverterFunctionDurationAlarm'])

      props = res['ConverterFunctionDurationAlarm']['Properties']
      expect(props['MetricName']).to eq('Duration')
      expect(props['Statistic']).to eq('Average')
      expect(props['Threshold']).to eq(5000)
      expect(props['AlarmActions']).to eq([arn])
    end

    it 'compiles a throttles alarm without actions when none specified' do
      alarm = Veltrunode::Model::Alarm.new(
        metric: :throttles,
        threshold: 2
      )

      res = described_class.compile(fn, alarm)
      expect(res.keys).to eq(['ConverterFunctionThrottlesAlarm'])

      props = res['ConverterFunctionThrottlesAlarm']['Properties']
      expect(props['MetricName']).to eq('Throttles')
      expect(props).not_to have_key('AlarmActions')
    end
  end
end
