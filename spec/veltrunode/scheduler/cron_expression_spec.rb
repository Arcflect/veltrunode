# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler/cron_expression'

RSpec.describe Veltrunode::Scheduler::CronExpression do
  describe 'parsing valid expressions' do
    it 'parses standard daily expression' do
      expr = described_class.new('cron(0 12 * * ? *)')
      expect(expr.minute_field.match?(0)).to be true
      expect(expr.hour_field.match?(12)).to be true
      expect(expr.day_of_month_field.match?(2026, 4, 1)).to be true
      expect(expr.month_field.match?(4)).to be true
      expect(expr.year_field.match?(2026)).to be true
    end

    it 'parses weekday expression with MON-FRI' do
      expr = described_class.new('cron(0 10 ? * MON-FRI *)')
      expect(expr.day_of_month_field.question_mark?).to be true
      # 2026-04-03 is Friday (EventBridge wday = 6)
      expect(expr.day_of_week_field.match?(2026, 4, 3)).to be true
      # 2026-04-05 is Sunday (EventBridge wday = 1)
      expect(expr.day_of_week_field.match?(2026, 4, 5)).to be false
    end

    it 'parses month names' do
      expr = described_class.new('cron(0 0 1 JAN,JUN,DEC ? *)')
      expect(expr.month_field.match?(1)).to be true
      expect(expr.month_field.match?(6)).to be true
      expect(expr.month_field.match?(12)).to be true
      expect(expr.month_field.match?(7)).to be false
    end

    it 'parses step values and ranges' do
      expr = described_class.new('cron(0/15 9-17 ? * 2-6 *)')
      expect(expr.minute_field.match?(0)).to be true
      expect(expr.minute_field.match?(15)).to be true
      expect(expr.minute_field.match?(30)).to be true
      expect(expr.minute_field.match?(45)).to be true
      expect(expr.minute_field.match?(10)).to be false

      expect(expr.hour_field.match?(9)).to be true
      expect(expr.hour_field.match?(17)).to be true
      expect(expr.hour_field.match?(18)).to be false
    end
  end

  describe 'calculating next occurrences' do
    let(:base_time) { Time.utc(2026, 4, 1, 10, 0, 0) }

    it 'calculates daily 12:00 occurrences' do
      expr = described_class.new('cron(0 12 * * ? *)')
      occurrences = expr.next_occurrences(3, from_time: base_time, timezone: 'UTC')

      expect(occurrences.size).to eq(3)
      expect(occurrences[0]).to eq(Time.utc(2026, 4, 1, 12, 0, 0))
      expect(occurrences[1]).to eq(Time.utc(2026, 4, 2, 12, 0, 0))
      expect(occurrences[2]).to eq(Time.utc(2026, 4, 3, 12, 0, 0))
    end

    it 'calculates weekday only occurrences' do
      # 2026-04-03 is Friday. Next weekdays are Mon 2026-04-06 and Tue 2026-04-07.
      expr = described_class.new('cron(0 18 ? * MON-FRI *)')
      from = Time.utc(2026, 4, 3, 19, 0, 0)
      occurrences = expr.next_occurrences(2, from_time: from, timezone: 'UTC')

      expect(occurrences.size).to eq(2)
      expect(occurrences[0]).to eq(Time.utc(2026, 4, 6, 18, 0, 0)) # Monday
      expect(occurrences[1]).to eq(Time.utc(2026, 4, 7, 18, 0, 0)) # Tuesday
    end

    it 'calculates last day of month (L)' do
      # In 2026, April has 30 days, May has 31 days.
      expr = described_class.new('cron(0 12 L * ? *)')
      occurrences = expr.next_occurrences(2, from_time: base_time, timezone: 'UTC')

      expect(occurrences.size).to eq(2)
      expect(occurrences[0]).to eq(Time.utc(2026, 4, 30, 12, 0, 0))
      expect(occurrences[1]).to eq(Time.utc(2026, 5, 31, 12, 0, 0))
    end

    it 'calculates 3rd Friday of the month (6#3)' do
      # April 2026: Fridays are 3rd, 10th, 17th (3rd Friday is 17th)
      expr = described_class.new('cron(0 15 ? * 6#3 *)')
      occurrences = expr.next_occurrences(1, from_time: base_time, timezone: 'UTC')

      expect(occurrences.size).to eq(1)
      expect(occurrences[0]).to eq(Time.utc(2026, 4, 17, 15, 0, 0))
    end

    it 'calculates nearest weekday to 15th (15W)' do
      # Aug 15, 2026 is Saturday -> nearest weekday is Friday Aug 14
      expr = described_class.new('cron(0 9 15W 8 ? 2026)')
      from = Time.utc(2026, 8, 1, 0, 0, 0)
      occurrences = expr.next_occurrences(1, from_time: from, timezone: 'UTC')

      expect(occurrences.size).to eq(1)
      expect(occurrences[0]).to eq(Time.utc(2026, 8, 14, 9, 0, 0))
    end

    it 'calculates occurrences in Asia/Tokyo timezone' do
      expr = described_class.new('cron(30 9 1 * ? *)') # 1st of every month at 09:30
      occurrences = expr.next_occurrences(2, from_time: base_time, timezone: 'Asia/Tokyo')

      expect(occurrences.size).to eq(2)
      expect(occurrences[0].year).to eq(2026)
      expect(occurrences[0].month).to eq(5)
      expect(occurrences[0].day).to eq(1)
      expect(occurrences[0].hour).to eq(9)
      expect(occurrences[0].min).to eq(30)
      expect(occurrences[0].utc_offset).to eq(9 * 3600)
    end
  end

  describe 'daylight saving time (DST) transitions' do
    it 'handles spring forward transition in America/New_York' do
      # 2026-03-08: 02:00 skips to 03:00 in America/New_York (EST -> EDT)
      # A schedule configured for 02:30 shifts to 03:30
      expr = described_class.new('cron(30 2 8 3 ? 2026)')
      from = Time.utc(2026, 3, 8, 0, 0, 0)
      occurrences = expr.next_occurrences(1, from_time: from, timezone: 'America/New_York')

      expect(occurrences.size).to eq(1)
      time = occurrences.first
      expect(time.hour).to eq(3)
      expect(time.min).to eq(30)
      expect(time.utc_offset).to eq(-4 * 3600) # EDT
    end

    it 'handles fall back transition in America/New_York' do
      # 2026-11-01: 01:00 to 02:00 repeats in America/New_York (EDT -> EST)
      # A schedule for 01:30 should run at the earlier EDT occurrence
      expr = described_class.new('cron(30 1 1 11 ? 2026)')
      from = Time.utc(2026, 11, 1, 0, 0, 0)
      occurrences = expr.next_occurrences(1, from_time: from, timezone: 'America/New_York')

      expect(occurrences.size).to eq(1)
      time = occurrences.first
      expect(time.hour).to eq(1)
      expect(time.min).to eq(30)
      expect(time.utc_offset).to eq(-4 * 3600) # EDT (-4h)
    end
  end

  describe 'error handling (VLT-SCHED-001)' do
    it 'raises error when field count is not 6' do
      expect { described_class.new('cron(0 12 * * *)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_field_count')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error when neither day-of-month nor day-of-week is ?' do
      expect { described_class.new('cron(0 12 * * * *)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('day_fields_question_mark_constraint')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error when both day-of-month and day-of-week are ?' do
      expect { described_class.new('cron(0 12 ? * ? *)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('day_fields_question_mark_constraint')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for out of range field values' do
      expect { described_class.new('cron(60 12 * * ? *)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_minute_field')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'raises error for invalid cron pattern syntax' do
      expect { described_class.new('cron()') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('invalid_format')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end
  end
end
