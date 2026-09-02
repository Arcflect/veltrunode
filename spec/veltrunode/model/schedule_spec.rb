# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Schedule do
  let(:valid_cron_attributes) do
    {
      name: 'daily_cron',
      target_function: 'my_function',
      expression_type: :cron,
      expression: '0 12 * * ? *',
      timezone: 'Asia/Tokyo',
      state: :enabled,
      flexible_window: { mode: :flexible, maximum_window_in_minutes: 15 },
      input: { 'key' => 'value' },
      retry_policy: { maximum_attempts: 10, maximum_event_age_in_seconds: 3600 },
      dlq: 'arn:aws:sqs:ap-northeast-1:123456789012:dlq',
      execution_role: 'arn:aws:iam::123456789012:role/scheduler-role'
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:schedule) { described_class.new(**valid_cron_attributes) }

      it 'correctly assigns all attributes' do
        expect(schedule.name).to eq('daily_cron')
        expect(schedule.target_function).to eq('my_function')
        expect(schedule.expression_type).to eq(:cron)
        expect(schedule.expression).to eq('0 12 * * ? *')
        expect(schedule.timezone).to eq('Asia/Tokyo')
        expect(schedule.state).to eq(:enabled)
        expect(schedule.flexible_window).to eq({ 'mode' => :flexible, 'maximum_window_in_minutes' => 15 })
        expect(schedule.input).to eq({ 'key' => 'value' })
        expect(schedule.retry_policy).to eq({ 'maximum_attempts' => 10, 'maximum_event_age_in_seconds' => 3600 })
        expect(schedule.dlq).to eq('arn:aws:sqs:ap-northeast-1:123456789012:dlq')
        expect(schedule.execution_role).to eq('arn:aws:iam::123456789012:role/scheduler-role')
      end

      it 'provides default values for optional attributes' do
        minimal = described_class.new(
          name: 'minimal',
          target_function: 'fn',
          expression_type: 'cron',
          expression: '0 12 * * ? *'
        )

        expect(minimal.expression_type).to eq(:cron)
        expect(minimal.timezone).to eq('UTC')
        expect(minimal.state).to eq(:enabled)
        expect(minimal.flexible_window).to eq({ 'mode' => :off })
        expect(minimal.input).to be_nil
        expect(minimal.retry_policy).to be_nil
        expect(minimal.dlq).to be_nil
        expect(minimal.execution_role).to be_nil
      end
    end

    context 'immutability' do
      subject(:schedule) { described_class.new(**valid_cron_attributes) }

      it 'freezes the instance and attributes' do
        expect(schedule).to be_frozen
        expect(schedule.name).to be_frozen
        expect(schedule.target_function).to be_frozen
        expect(schedule.expression).to be_frozen
        expect(schedule.flexible_window).to be_frozen
        expect(schedule.input).to be_frozen
        expect(schedule.retry_policy).to be_frozen
      end

      it 'prevents modification of attributes' do
        expect { schedule.input['new_key'] = 'val' }.to raise_error(FrozenError)
      end
    end

    context 'expression_type and expression validation' do
      describe 'cron type' do
        it 'allows valid 6-field AWS cron expressions with or without cron() wrapper' do
          s1 = described_class.new(
            name: 's1', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *'
          )
          s2 = described_class.new(
            name: 's2', target_function: 'fn', expression_type: :cron, expression: 'cron(0 12 * * ? *)'
          )

          expect(s1.expression).to eq('0 12 * * ? *')
          expect(s2.expression).to eq('cron(0 12 * * ? *)')
        end

        it 'raises ValidationError when cron expression has invalid number of fields' do
          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ?'
            )
          end.to raise_error(Veltrunode::ValidationError, /6 fields/)

          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? * 2026'
            )
          end.to raise_error(Veltrunode::ValidationError, /6 fields/)
        end
      end

      describe 'rate type' do
        it 'allows valid rate(N unit) expressions' do
          r1 = described_class.new(
            name: 'r1', target_function: 'fn', expression_type: :rate, expression: 'rate(1 minute)'
          )
          r2 = described_class.new(
            name: 'r2', target_function: 'fn', expression_type: :rate, expression: 'rate(5 minutes)'
          )
          r3 = described_class.new(
            name: 'r3', target_function: 'fn', expression_type: :rate, expression: 'rate(1 hour)'
          )
          r4 = described_class.new(
            name: 'r4', target_function: 'fn', expression_type: :rate, expression: 'rate(1 day)'
          )

          expect(r1.expression).to eq('rate(1 minute)')
          expect(r2.expression).to eq('rate(5 minutes)')
          expect(r3.expression).to eq('rate(1 hour)')
          expect(r4.expression).to eq('rate(1 day)')
        end

        it 'raises ValidationError when rate expression format is invalid' do
          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :rate, expression: 'rate(invalid)'
            )
          end.to raise_error(Veltrunode::ValidationError, /rate\(N unit\)/)

          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :rate, expression: 'every 5 minutes'
            )
          end.to raise_error(Veltrunode::ValidationError, /rate\(N unit\)/)
        end
      end

      describe 'at type' do
        it 'allows valid ISO 8601 date-time expressions with or without at() wrapper' do
          a1 = described_class.new(
            name: 'a1', target_function: 'fn', expression_type: :at, expression: '2026-08-01T12:00:00Z'
          )
          a2 = described_class.new(
            name: 'a2', target_function: 'fn', expression_type: :at, expression: 'at(2026-08-01T12:00:00+09:00)'
          )

          expect(a1.expression).to eq('2026-08-01T12:00:00Z')
          expect(a2.expression).to eq('at(2026-08-01T12:00:00+09:00)')
        end

        it 'raises ValidationError when at expression is not valid ISO 8601' do
          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :at, expression: 'invalid-date'
            )
          end.to raise_error(Veltrunode::ValidationError, /ISO 8601/)

          expect do
            described_class.new(
              name: 's', target_function: 'fn', expression_type: :at, expression: 'at(not-a-date)'
            )
          end.to raise_error(Veltrunode::ValidationError, /ISO 8601/)
        end
      end
    end

    context 'timezone validation' do
      it 'allows valid IANA timezone names' do
        s1 = described_class.new(
          name: 's1', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *', timezone: 'UTC'
        )
        s2 = described_class.new(
          name: 's2', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *', timezone: 'Asia/Tokyo'
        )
        s3 = described_class.new(
          name: 's3',
          target_function: 'fn',
          expression_type: :cron,
          expression: '0 12 * * ? *',
          timezone: 'America/New_York'
        )

        expect(s1.timezone).to eq('UTC')
        expect(s2.timezone).to eq('Asia/Tokyo')
        expect(s3.timezone).to eq('America/New_York')
      end

      it 'raises ValidationError when timezone format is invalid' do
        expect do
          described_class.new(
            name: 's',
            target_function: 'fn',
            expression_type: :cron,
            expression: '0 12 * * ? *',
            timezone: 'invalid tz!'
          )
        end.to raise_error(Veltrunode::ValidationError, /timezone/)
      end
    end

    context 'dlq validation' do
      it 'allows valid SQS queue ARNs' do
        s1 = described_class.new(
          name: 's1', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          dlq: 'arn:aws:sqs:ap-northeast-1:123456789012:my-dead-letter-queue'
        )
        s2 = described_class.new(
          name: 's2', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          dlq: 'arn:aws:sqs:us-east-1:123456789012:fifo-queue.fifo'
        )

        expect(s1.dlq).to eq('arn:aws:sqs:ap-northeast-1:123456789012:my-dead-letter-queue')
        expect(s2.dlq).to eq('arn:aws:sqs:us-east-1:123456789012:fifo-queue.fifo')
      end

      it 'allows symbolic DLQ queue names and Hash references' do
        s1 = described_class.new(
          name: 's1', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          dlq: 'batch_dlq'
        )
        s2 = described_class.new(
          name: 's2', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          dlq: { 'Ref' => 'DlqQueueParam' }
        )

        expect(s1.dlq).to eq('batch_dlq')
        expect(s2.dlq).to eq({ 'Ref' => 'DlqQueueParam' })
      end

      it 'raises ValidationError when dlq is an invalid ARN or non-SQS ARN' do
        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
            dlq: 'arn:aws:sns:ap-northeast-1:123456789012:my-topic'
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid SQS DLQ ARN/)

        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
            dlq: 'arn:aws:sqs:invalid-arn'
          )
        end.to raise_error(Veltrunode::ValidationError, /Invalid SQS DLQ ARN/)
      end
    end

    context 'retry_policy validation' do
      it 'allows maximum_attempts between 0 and 185' do
        s0 = described_class.new(
          name: 's0', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          retry_policy: { maximum_attempts: 0 }
        )
        s185 = described_class.new(
          name: 's185', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
          retry_policy: { maximum_attempts: 185 }
        )

        expect(s0.retry_policy['maximum_attempts']).to eq(0)
        expect(s185.retry_policy['maximum_attempts']).to eq(185)
      end

      it 'raises ValidationError when maximum_attempts is out of 0..185 range' do
        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
            retry_policy: { maximum_attempts: -1 }
          )
        end.to raise_error(Veltrunode::ValidationError, /maximum_attempts/)

        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *',
            retry_policy: { maximum_attempts: 186 }
          )
        end.to raise_error(Veltrunode::ValidationError, /maximum_attempts/)
      end
    end

    context 'other validations' do
      it 'raises ValidationError when name or target_function is missing' do
        expect do
          described_class.new(
            name: nil, target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *'
          )
        end.to raise_error(Veltrunode::ValidationError, /name/)

        expect do
          described_class.new(
            name: 's', target_function: nil, expression_type: :cron, expression: '0 12 * * ? *'
          )
        end.to raise_error(Veltrunode::ValidationError, /target_function/)
      end

      it 'raises ValidationError when expression_type or state is invalid' do
        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :unknown, expression: '0 12 * * ? *'
          )
        end.to raise_error(Veltrunode::ValidationError, /expression_type/)

        expect do
          described_class.new(
            name: 's', target_function: 'fn', expression_type: :cron, expression: '0 12 * * ? *', state: :invalid
          )
        end.to raise_error(Veltrunode::ValidationError, /state/)
      end
    end
  end
end
