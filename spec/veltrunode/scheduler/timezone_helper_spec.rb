# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler/timezone_helper'

RSpec.describe Veltrunode::Scheduler::TimezoneHelper do
  describe '.resolve_timezone' do
    it 'resolves standard IANA timezone' do
      tz = described_class.resolve_timezone('Asia/Tokyo')
      expect(tz.identifier).to eq('Asia/Tokyo')
    end

    it 'defaults to UTC if empty' do
      tz = described_class.resolve_timezone('')
      expect(tz.identifier).to eq('UTC')
    end

    it 'raises ScheduleExpressionError with unrecognized_timezone for invalid identifier' do
      expect do
        described_class.resolve_timezone('Invalid/Timezone')
      end.to raise_error(
        Veltrunode::Scheduler::ScheduleExpressionError,
        "Invalid timezone identifier 'Invalid/Timezone'"
      )
    end
  end

  describe '.local_to_time' do
    it 'converts local time components to Time in Asia/Tokyo' do
      time = described_class.local_to_time(2026, 4, 1, 10, 30, 0, 'Asia/Tokyo')
      expect(time.year).to eq(2026)
      expect(time.month).to eq(4)
      expect(time.day).to eq(1)
      expect(time.hour).to eq(10)
      expect(time.min).to eq(30)
      expect(time.utc_offset).to eq(9 * 3600)
    end

    it 'handles spring forward (DST gap) by shifting forward by 1 hour' do
      # America/New_York 2026: March 8 02:00:00 skipped to 03:00:00 (EST to EDT)
      time = described_class.local_to_time(2026, 3, 8, 2, 30, 0, 'America/New_York')
      expect(time.hour).to eq(3)
      expect(time.min).to eq(30)
      expect(time.utc_offset).to eq(-4 * 3600)
    end

    it 'handles fall back (DST ambiguity) by picking daylight saving time first' do
      # America/New_York 2026: Nov 1 01:00:00 to 02:00:00 repeated (EDT then EST)
      time = described_class.local_to_time(2026, 11, 1, 1, 30, 0, 'America/New_York')
      expect(time.hour).to eq(1)
      expect(time.min).to eq(30)
      expect(time.utc_offset).to eq(-4 * 3600) # EDT (-4)
    end
  end
end
