# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/compiler/cloudformation/dlq_alarm_compiler'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Compiler::CloudFormation::DlqAlarmCompiler do
  describe '.compile' do
    it 'compiles an SQS DLQ messages visible alarm with default properties' do
      res = described_class.compile(:nightly_dlq)
      expect(res.keys).to eq(['NightlyDlqQueueAlarm'])

      alarm_def = res['NightlyDlqQueueAlarm']
      expect(alarm_def['Type']).to eq('AWS::CloudWatch::Alarm')

      props = alarm_def['Properties']
      expect(props['AlarmName']).to eq({ 'Fn::Sub' => '${AWS::StackName}-NightlyDlqQueueAlarm' })
      expected_desc = 'CloudWatch Alarm for SQS DLQ nightly_dlq ApproximateNumberOfMessagesVisible'
      expect(props['AlarmDescription']).to eq(expected_desc)
      expect(props['Namespace']).to eq('AWS/SQS')
      expect(props['MetricName']).to eq('ApproximateNumberOfMessagesVisible')
      expect(props['Dimensions']).to eq([{ 'Name' => 'QueueName',
                                           'Value' => { 'Fn::GetAtt' => %w[NightlyDlqQueue QueueName] } }])
      expect(props['Statistic']).to eq('Maximum')
      expect(props['ComparisonOperator']).to eq('GreaterThanThreshold')
      expect(props['Threshold']).to eq(0)
      expect(props['EvaluationPeriods']).to eq(1)
      expect(props['Period']).to eq(60)
      expect(props['TreatMissingData']).to eq('notBreaching')
      expect(props).not_to have_key('AlarmActions')
    end

    it 'includes AlarmActions when topic reference is provided' do
      topic_ref = Veltrunode::DSL::Reference.new(:alert_topic)
      res = described_class.compile('orders_dlq', topic: topic_ref)

      alarm_def = res['OrdersDlqQueueAlarm']
      props = alarm_def['Properties']
      expect(props['AlarmActions']).to eq([{ 'Ref' => 'AlertTopic' }])
    end

    it 'includes AlarmActions when topic ARN is provided' do
      topic_arn = 'arn:aws:sns:ap-northeast-1:123456789012:my-alerts'
      res = described_class.compile(:orders_dlq, topic: topic_arn)

      alarm_def = res['OrdersDlqQueueAlarm']
      props = alarm_def['Properties']
      expect(props['AlarmActions']).to eq([topic_arn])
    end
  end
end
