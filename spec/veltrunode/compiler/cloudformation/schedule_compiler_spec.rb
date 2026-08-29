# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/schedule_compiler'
require 'veltrunode/model/schedule'

RSpec.describe Veltrunode::Compiler::CloudFormation::ScheduleCompiler do
  let(:minimal_cron_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'daily_sync',
      target_function: 'convert',
      expression_type: :cron,
      expression: '0 12 * * ? *'
    )
  end

  let(:wrapped_cron_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'daily_sync_schedule',
      target_function: 'convert',
      expression_type: :cron,
      expression: 'cron(0 12 * * ? *)',
      timezone: 'Asia/Tokyo',
      state: :disabled
    )
  end

  let(:rate_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'periodic_check',
      target_function: 'check_health',
      expression_type: :rate,
      expression: 'rate(5 minutes)',
      flexible_window: { mode: :flexible, maximum_window_in_minutes: 15 }
    )
  end

  let(:at_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'one_off_task',
      target_function: 'run_once',
      expression_type: :at,
      expression: '2026-08-01T12:00:00Z'
    )
  end

  let(:full_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'batch_export',
      target_function: 'exporter',
      expression_type: :cron,
      expression: '0 2 * * ? *',
      timezone: 'Asia/Tokyo',
      state: :enabled,
      flexible_window: { mode: :flexible, maximum_window_in_minutes: 30 },
      input: { 'environment' => 'production', 'batch_size' => 100 },
      retry_policy: { maximum_attempts: 5, maximum_event_age_in_seconds: 3600 },
      dlq: 'batch_dlq',
      execution_role: 'arn:aws:iam::123456789012:role/CustomSchedulerRole'
    )
  end

  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for Schedules' do
      expect(described_class.logical_id_for('daily_sync')).to eq('DailySyncSchedule')
      expect(described_class.logical_id_for('daily_sync_schedule')).to eq('DailySyncSchedule')
      expect(described_class.logical_id_for('periodic_check')).to eq('PeriodicCheckSchedule')
      expect(described_class.logical_id_for('')).to eq('Schedule')
    end
  end

  describe '#to_h and properties mapping' do
    it 'compiles a minimal cron schedule' do
      result = described_class.compile(minimal_cron_schedule)

      expect(result).to have_key('DailySyncSchedule')
      resource = result['DailySyncSchedule']
      expect(resource['Type']).to eq('AWS::Scheduler::Schedule')

      props = resource['Properties']
      expect(props['ScheduleExpression']).to eq('cron(0 12 * * ? *)')
      expect(props['ScheduleExpressionTimezone']).to eq('UTC')
      expect(props['State']).to eq('ENABLED')
      expect(props['FlexibleTimeWindow']).to eq({ 'Mode' => 'OFF' })

      target = props['Target']
      expect(target['Arn']).to eq({ 'Fn::GetAtt' => %w[ConvertFunction Arn] })
      expect(target['RoleArn']).to eq({ 'Fn::GetAtt' => %w[DailySyncScheduleRole Arn] })
      expect(target).not_to have_key('Input')
      expect(target).not_to have_key('RetryPolicy')
      expect(target).not_to have_key('DeadLetterConfig')
    end

    it 'handles wrapped cron expressions, timezone, and disabled state' do
      result = described_class.compile(wrapped_cron_schedule)
      props = result['DailySyncSchedule']['Properties']

      expect(props['ScheduleExpression']).to eq('cron(0 12 * * ? *)')
      expect(props['ScheduleExpressionTimezone']).to eq('Asia/Tokyo')
      expect(props['State']).to eq('DISABLED')
    end

    it 'compiles a rate schedule with flexible time window' do
      result = described_class.compile(rate_schedule)
      props = result['PeriodicCheckSchedule']['Properties']

      expect(props['ScheduleExpression']).to eq('rate(5 minutes)')
      expect(props['FlexibleTimeWindow']).to eq({
                                                  'Mode' => 'FLEXIBLE',
                                                  'MaximumWindowInMinutes' => 15
                                                })
      expect(props['Target']['Arn']).to eq({ 'Fn::GetAtt' => %w[CheckHealthFunction Arn] })
      expect(props['Target']['RoleArn']).to eq({ 'Fn::GetAtt' => %w[PeriodicCheckScheduleRole Arn] })
    end

    it 'compiles an at schedule with ISO 8601 timestamp' do
      result = described_class.compile(at_schedule)
      props = result['OneOffTaskSchedule']['Properties']

      expect(props['ScheduleExpression']).to eq('at(2026-08-01T12:00:00Z)')
    end

    it 'compiles a full schedule with input JSON, retry policy, DLQ, and custom execution role' do
      result = described_class.compile(full_schedule)
      props = result['BatchExportSchedule']['Properties']

      expect(props['ScheduleExpression']).to eq('cron(0 2 * * ? *)')
      expect(props['ScheduleExpressionTimezone']).to eq('Asia/Tokyo')
      expect(props['State']).to eq('ENABLED')
      expect(props['FlexibleTimeWindow']).to eq({
                                                  'Mode' => 'FLEXIBLE',
                                                  'MaximumWindowInMinutes' => 30
                                                })

      target = props['Target']
      expect(target['Arn']).to eq({ 'Fn::GetAtt' => %w[ExporterFunction Arn] })
      expect(target['RoleArn']).to eq('arn:aws:iam::123456789012:role/CustomSchedulerRole')
      expect(target['Input']).to eq('{"environment":"production","batch_size":100}')
      expect(target['RetryPolicy']).to eq({
                                            'MaximumEventAgeInSeconds' => 3600,
                                            'MaximumRetryAttempts' => 5
                                          })
      expect(target['DeadLetterConfig']).to eq({
                                                 'Arn' => { 'Fn::GetAtt' => %w[BatchDlqQueue Arn] }
                                               })
    end

    it 'uses explicit target_function_arn and execution_role_arn from context when provided' do
      ctx = {
        target_function_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:function:custom_fn',
        execution_role_arn: 'arn:aws:iam::123456789012:role/custom_role'
      }
      result = described_class.compile(minimal_cron_schedule, context: ctx)
      target = result['DailySyncSchedule']['Properties']['Target']

      expect(target['Arn']).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:custom_fn')
      expect(target['RoleArn']).to eq('arn:aws:iam::123456789012:role/custom_role')
    end

    it 'formats raw SQS queue ARN string in DeadLetterConfig when provided as full ARN' do
      dlq_schedule = Veltrunode::Model::Schedule.new(
        name: 'dlq_task',
        target_function: 'fn',
        expression_type: :cron,
        expression: '0 0 * * ? *',
        dlq: 'arn:aws:sqs:ap-northeast-1:123456789012:my-dead-letter-queue'
      )

      result = described_class.compile(dlq_schedule)
      target_dlq = result['DlqTaskSchedule']['Properties']['Target']['DeadLetterConfig']
      expected_arn = 'arn:aws:sqs:ap-northeast-1:123456789012:my-dead-letter-queue'
      expect(target_dlq).to eq({ 'Arn' => expected_arn })
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(full_schedule)
      resource_keys = result['BatchExportSchedule'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['BatchExportSchedule']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)

      target_keys = result['BatchExportSchedule']['Properties']['Target'].keys
      expect(target_keys).to eq(target_keys.sort)
    end

    it 'produces deterministic YAML output across multiple compilations' do
      yaml1 = described_class.to_yaml(full_schedule)
      yaml2 = described_class.to_yaml(full_schedule)

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches expected golden YAML output for minimal cron schedule' do
      expected_yaml = <<~YAML
        ---
        DailySyncSchedule:
          Properties:
            FlexibleTimeWindow:
              Mode: 'OFF'
            ScheduleExpression: cron(0 12 * * ? *)
            ScheduleExpressionTimezone: UTC
            State: ENABLED
            Target:
              Arn:
                Fn::GetAtt:
                - ConvertFunction
                - Arn
              RoleArn:
                Fn::GetAtt:
                - DailySyncScheduleRole
                - Arn
          Type: AWS::Scheduler::Schedule
      YAML

      generated_yaml = described_class.to_yaml(minimal_cron_schedule)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end

    it 'matches expected golden YAML output for rate schedule with flexible window' do
      expected_yaml = <<~YAML
        ---
        PeriodicCheckSchedule:
          Properties:
            FlexibleTimeWindow:
              MaximumWindowInMinutes: 15
              Mode: FLEXIBLE
            ScheduleExpression: rate(5 minutes)
            ScheduleExpressionTimezone: UTC
            State: ENABLED
            Target:
              Arn:
                Fn::GetAtt:
                - CheckHealthFunction
                - Arn
              RoleArn:
                Fn::GetAtt:
                - PeriodicCheckScheduleRole
                - Arn
          Type: AWS::Scheduler::Schedule
      YAML

      generated_yaml = described_class.to_yaml(rate_schedule)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end

    it 'matches expected golden YAML output for one-time at schedule' do
      expected_yaml = <<~YAML
        ---
        OneOffTaskSchedule:
          Properties:
            FlexibleTimeWindow:
              Mode: 'OFF'
            ScheduleExpression: at(2026-08-01T12:00:00Z)
            ScheduleExpressionTimezone: UTC
            State: ENABLED
            Target:
              Arn:
                Fn::GetAtt:
                - RunOnceFunction
                - Arn
              RoleArn:
                Fn::GetAtt:
                - OneOffTaskScheduleRole
                - Arn
          Type: AWS::Scheduler::Schedule
      YAML

      generated_yaml = described_class.to_yaml(at_schedule)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end

    it 'matches expected golden YAML output for full schedule' do
      expected_yaml = <<~YAML
        ---
        BatchExportSchedule:
          Properties:
            FlexibleTimeWindow:
              MaximumWindowInMinutes: 30
              Mode: FLEXIBLE
            ScheduleExpression: cron(0 2 * * ? *)
            ScheduleExpressionTimezone: Asia/Tokyo
            State: ENABLED
            Target:
              Arn:
                Fn::GetAtt:
                - ExporterFunction
                - Arn
              DeadLetterConfig:
                Arn:
                  Fn::GetAtt:
                  - BatchDlqQueue
                  - Arn
              Input: '{"environment":"production","batch_size":100}'
              RetryPolicy:
                MaximumEventAgeInSeconds: 3600
                MaximumRetryAttempts: 5
              RoleArn: arn:aws:iam::123456789012:role/CustomSchedulerRole
          Type: AWS::Scheduler::Schedule
      YAML

      generated_yaml = described_class.to_yaml(full_schedule)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
