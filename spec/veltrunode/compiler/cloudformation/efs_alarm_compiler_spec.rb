# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Compiler::CloudFormation::EfsAlarmCompiler do
  let(:fs_id) { 'fs-0123456789abcdef0' }

  describe '.compile' do
    it 'compiles BurstCreditBalance and PercentIOLimit CloudWatch alarms with default thresholds' do
      mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'shared_data',
        local_path: '/mnt/shared',
        managed_access_point: {
          file_system_id: fs_id,
          alarms: true
        }
      )

      resources = described_class.compile(mount)

      expect(resources.keys).to contain_exactly(
        'SharedDataBurstCreditBalanceAlarm',
        'SharedDataPercentIOLimitAlarm'
      )

      bc_alarm = resources['SharedDataBurstCreditBalanceAlarm']
      expect(bc_alarm['Type']).to eq('AWS::CloudWatch::Alarm')
      expect(bc_alarm['Properties']).to include(
        'Namespace' => 'AWS/EFS',
        'MetricName' => 'BurstCreditBalance',
        'ComparisonOperator' => 'LessThanOrEqualToThreshold',
        'Statistic' => 'Minimum',
        'Threshold' => 1_073_741_824,
        'Period' => 300,
        'EvaluationPeriods' => 1,
        'TreatMissingData' => 'notBreaching',
        'Dimensions' => [{ 'Name' => 'FileSystemId', 'Value' => fs_id }]
      )

      io_alarm = resources['SharedDataPercentIOLimitAlarm']
      expect(io_alarm['Type']).to eq('AWS::CloudWatch::Alarm')
      expect(io_alarm['Properties']).to include(
        'Namespace' => 'AWS/EFS',
        'MetricName' => 'PercentIOLimit',
        'ComparisonOperator' => 'GreaterThanOrEqualToThreshold',
        'Statistic' => 'Average',
        'Threshold' => 80,
        'Period' => 300,
        'EvaluationPeriods' => 1,
        'TreatMissingData' => 'notBreaching',
        'Dimensions' => [{ 'Name' => 'FileSystemId', 'Value' => fs_id }]
      )
    end

    it 'compiles custom thresholds and SNS notification topic references' do
      mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'work_storage',
        local_path: '/mnt/work',
        alarms: {
          burst_credit_balance: 500_000_000,
          percent_io_limit: 90,
          topic: Veltrunode::DSL::Reference.new(:alert_topic)
        }
      )

      resources = described_class.compile(mount)

      bc_props = resources['WorkStorageBurstCreditBalanceAlarm']['Properties']
      expect(bc_props['Threshold']).to eq(500_000_000)
      expect(bc_props['Dimensions']).to eq(
        [{ 'Name' => 'FileSystemId', 'Value' => { 'Ref' => 'WorkStorageFileSystem' } }]
      )
      expect(bc_props['AlarmActions']).to eq([{ 'Ref' => 'AlertTopic' }])

      io_props = resources['WorkStoragePercentIOLimitAlarm']['Properties']
      expect(io_props['Threshold']).to eq(90)
      expect(io_props['AlarmActions']).to eq([{ 'Ref' => 'AlertTopic' }])
    end
  end
end
