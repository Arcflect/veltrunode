# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler/at_expression'

RSpec.describe Veltrunode::Scheduler::AtExpression do
  describe 'parsing valid expressions' do
    it 'parses local ISO 8601 without offset' do
      expr = described_class.new('at(2026-10-01T15:30:00)')
      expect(expr.year).to eq(2026)
      expect(expr.month).to eq(10)
      expect(expr.day).to eq(1)
      expect(expr.hour).to eq(15)
      expect(expr.min).to eq(30)
      expect(expr.sec).to eq(0)
      expect(expr.has_offset).to be false
    end

    it 'parses ISO 8601 with UTC Z offset' do
      expr = described_class.new('at(2026-10-01T15:30:00Z)')
      expect(expr.has_offset).to be true
      expect(expr.datetime_string).to eq('2026-10-01T15:30:00Z')
    end

    it 'parses ISO 8601 with timezone offset' do
      expr = described_class.new('at(2026-10-01T15:30:00+09:00)')
      expect(expr.has_offset).to be true
    end
  end

  describe 'calculating next occurrences' do
    it 'returns scheduled time when future' do
      expr = described_class.new('at(2026-10-01T15:00:00)')
      from_time = Time.utc(2026, 10, 1, 14, 0, 0)
      occurrences = expr.next_occurrences(5, from_time: from_time, timezone: 'UTC')

      expect(occurrences.size).to eq(1)
      expect(occurrences.first).to eq(Time.utc(2026, 10, 1, 15, 0, 0))
    end

    it 'returns empty array when scheduled time is in the past' do
      expr = described_class.new('at(2026-10-01T15:00:00)')
      from_time = Time.utc(2026, 10, 1, 16, 0, 0)
      occurrences = expr.next_occurrences(5, from_time: from_time, timezone: 'UTC')

      expect(occurrences).to be_empty
      expect(expr.next_occurrence(from_time: from_time, timezone: 'UTC')).to be_nil
    end

    it 'interprets datetime in specified timezone when without offset' do
      expr = described_class.new('at(2026-10-01T15:00:00)')
      from_time = Time.utc(2026, 10, 1, 0, 0, 0)
      occurrences = expr.next_occurrences(1, from_time: from_time, timezone: 'Asia/Tokyo')

      expect(occurrences.size).to eq(1)
      time = occurrences.first
      expect(time.hour).to eq(15)
      expect(time.utc_offset).to eq(9 * 3600)
    end

    it 'converts offset datetime to target timezone' do
      expr = described_class.new('at(2026-10-01T15:00:00Z)') # 15:00 UTC
      from_time = Time.utc(2026, 10, 1, 0, 0, 0)
      occurrences = expr.next_occurrences(1, from_time: from_time, timezone: 'Asia/Tokyo')

      expect(occurrences.size).to eq(1)
      time = occurrences.first
      expect(time.hour).to eq(0) # 15:00 UTC is next day 00:00 JST
      expect(time.day).to eq(2)
      expect(time.utc_offset).to eq(9 * 3600)
    end

    it 'returns empty array when count is 0 or negative' do
      expr = described_class.new('at(2026-10-01T15:00:00)')
      from_time = Time.utc(2026, 10, 1, 0, 0, 0)
      expect(expr.next_occurrences(0, from_time: from_time)).to eq([])
      expect(expr.next_occurrences(-1, from_time: from_time)).to eq([])
    end
  end

  describe 'error handling (VLT-SCHED-001)' do
    it 'raises error for invalid format syntax' do
      expect { described_class.new('at()') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_format')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for non-ISO8601 string' do
      expect { described_class.new('at(2026/10/01 15:00:00)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_datetime_format')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for invalid calendar date' do
      expect { described_class.new('at(2026-02-30T10:00:00)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_datetime_values')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for out of range time components' do
      expect { described_class.new('at(2026-10-01T25:00:00)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_datetime_values')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end
  end
end
