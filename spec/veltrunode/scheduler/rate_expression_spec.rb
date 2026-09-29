# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler/rate_expression'

RSpec.describe Veltrunode::Scheduler::RateExpression do
  describe 'parsing valid expressions' do
    it 'parses rate(1 minute)' do
      expr = described_class.new('rate(1 minute)')
      expect(expr.value).to eq(1)
      expect(expr.unit).to eq('minute')
      expect(expr.interval_seconds).to eq(60)
    end

    it 'parses rate(5 minutes)' do
      expr = described_class.new('rate(5 minutes)')
      expect(expr.value).to eq(5)
      expect(expr.unit).to eq('minutes')
      expect(expr.interval_seconds).to eq(300)
    end

    it 'parses rate(1 hour)' do
      expr = described_class.new('rate(1 hour)')
      expect(expr.value).to eq(1)
      expect(expr.unit).to eq('hour')
      expect(expr.interval_seconds).to eq(3600)
    end

    it 'parses rate(2 hours)' do
      expr = described_class.new('rate(2 hours)')
      expect(expr.value).to eq(2)
      expect(expr.unit).to eq('hours')
      expect(expr.interval_seconds).to eq(7200)
    end

    it 'parses rate(1 day)' do
      expr = described_class.new('rate(1 day)')
      expect(expr.value).to eq(1)
      expect(expr.unit).to eq('day')
      expect(expr.interval_seconds).to eq(86_400)
    end

    it 'parses rate(7 days)' do
      expr = described_class.new('rate(7 days)')
      expect(expr.value).to eq(7)
      expect(expr.unit).to eq('days')
      expect(expr.interval_seconds).to eq(7 * 86_400)
    end
  end

  describe 'calculating next occurrences' do
    let(:base_time) { Time.utc(2026, 4, 1, 12, 0, 0) }

    it 'calculates 3 occurrences for rate(15 minutes)' do
      expr = described_class.new('rate(15 minutes)')
      occurrences = expr.next_occurrences(3, from_time: base_time, timezone: 'UTC')

      expect(occurrences.size).to eq(3)
      expect(occurrences[0]).to eq(Time.utc(2026, 4, 1, 12, 15, 0))
      expect(occurrences[1]).to eq(Time.utc(2026, 4, 1, 12, 30, 0))
      expect(occurrences[2]).to eq(Time.utc(2026, 4, 1, 12, 45, 0))
    end

    it 'calculates occurrences in Asia/Tokyo timezone' do
      expr = described_class.new('rate(1 hour)')
      occurrences = expr.next_occurrences(2, from_time: base_time, timezone: 'Asia/Tokyo')

      expect(occurrences.size).to eq(2)
      expect(occurrences[0].hour).to eq(22) # 12:00 UTC + 9h + 1h = 22:00 JST
      expect(occurrences[0].utc_offset).to eq(9 * 3600)
      expect(occurrences[1].hour).to eq(23)
    end

    it 'returns empty array when count is 0 or negative' do
      expr = described_class.new('rate(1 hour)')
      expect(expr.next_occurrences(0, from_time: base_time)).to eq([])
      expect(expr.next_occurrences(-1, from_time: base_time)).to eq([])
    end

    it 'calculates single next_occurrence' do
      expr = described_class.new('rate(1 hour)')
      next_time = expr.next_occurrence(from_time: base_time, timezone: 'UTC')
      expect(next_time).to eq(Time.utc(2026, 4, 1, 13, 0, 0))
    end
  end

  describe 'error handling (VLT-SCHED-001)' do
    it 'raises error for value equal to 0' do
      expect { described_class.new('rate(0 minutes)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('value_must_be_greater_than_zero')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error when plural unit is used with value 1' do
      expect { described_class.new('rate(1 minutes)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('singular_unit_expected')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error when singular unit is used with value greater than 1' do
      expect { described_class.new('rate(5 minute)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('plural_unit_expected')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for unsupported units' do
      expect { described_class.new('rate(10 seconds)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('unknown_unit')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for malformed rate syntax' do
      expect { described_class.new('rate(foo)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_format')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end
  end
end
