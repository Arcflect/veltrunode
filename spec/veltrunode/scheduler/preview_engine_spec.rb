# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler'
require 'veltrunode/model/schedule'

RSpec.describe Veltrunode::Scheduler::PreviewEngine do
  describe '.preview' do
    let(:base_time) { Time.utc(2026, 4, 1, 0, 0, 0) }

    context 'with cron expression in Asia/Tokyo' do
      let(:schedule) do
        Veltrunode::Model::Schedule.new(
          name: 'daily-tokyo',
          target_function: 'my_func',
          expression_type: :cron,
          expression: 'cron(30 9 1 * ? *)',
          timezone: 'Asia/Tokyo'
        )
      end

      it 'calculates next N occurrences correctly without DST transitions' do
        result = described_class.preview(schedule, count: 3, from_time: base_time)

        expect(result.schedule_name).to eq('daily-tokyo')
        expect(result.target_function).to eq('my_func')
        expect(result.expression).to eq('cron(30 9 1 * ? *)')
        expect(result.expression_type).to eq(:cron)
        expect(result.timezone).to eq('Asia/Tokyo')
        expect(result.count).to eq(3)
        expect(result.occurrences.size).to eq(3)

        # Occurrence 1: 2026-04-01 09:30:00 JST (+09:00) / 2026-04-01 00:30:00 UTC
        occ1 = result.occurrences[0]
        expect(occ1.sequence).to eq(1)
        expect(occ1.timezone_abbr).to eq('JST')
        expect(occ1.utc_offset).to eq('+09:00')
        expect(occ1.dst?).to be(false)
        expect(occ1.local_iso8601).to eq('2026-04-01T09:30:00+09:00')
        expect(occ1.utc_iso8601).to eq('2026-04-01T00:30:00Z')
        expect(occ1.dst_transition).to be_nil

        # Occurrence 2: 2026-05-01 09:30:00 JST (+09:00)
        occ2 = result.occurrences[1]
        expect(occ2.local_iso8601).to eq('2026-05-01T09:30:00+09:00')

        # No DST in Asia/Tokyo
        expect(result.dst_transitions).to be_empty
        expect(result.disclaimer).to include('estimate for reference only')
      end
    end

    context 'with rate expression' do
      let(:schedule) do
        {
          name: 'frequent-job',
          target_function: 'worker',
          expression: 'rate(15 minutes)',
          timezone: 'UTC'
        }
      end

      it 'calculates occurrences at the specified interval' do
        result = described_class.preview(schedule, count: 4, from_time: base_time)

        expect(result.schedule_name).to eq('frequent-job')
        expect(result.expression_type).to eq(:rate)
        expect(result.occurrences.size).to eq(4)

        expect(result.occurrences[0].utc_iso8601).to eq('2026-04-01T00:15:00Z')
        expect(result.occurrences[1].utc_iso8601).to eq('2026-04-01T00:30:00Z')
        expect(result.occurrences[2].utc_iso8601).to eq('2026-04-01T00:45:00Z')
        expect(result.occurrences[3].utc_iso8601).to eq('2026-04-01T01:00:00Z')
      end
    end

    context 'with DST spring forward transition in America/New_York' do
      # 2026-03-08: 02:00 skips to 03:00 (EST -> EDT)
      let(:from_before_spring_forward) { Time.utc(2026, 3, 6, 0, 0, 0) }
      let(:schedule) do
        Veltrunode::Model::Schedule.new(
          name: 'dst-spring-test',
          target_function: 'cleaner',
          expression_type: :cron,
          expression: 'cron(30 2 * * ? *)', # 02:30 daily
          timezone: 'America/New_York'
        )
      end

      it 'detects DST spring forward transition and displays shift notice for skipped hour' do
        result = described_class.preview(schedule, count: 4, from_time: from_before_spring_forward)

        expect(result.occurrences.size).to eq(4)

        # 2026-03-06: EST
        occ1 = result.occurrences[0]
        expect(occ1.timezone_abbr).to eq('EST')
        expect(occ1.utc_offset).to eq('-05:00')
        expect(occ1.dst?).to be(false)
        expect(occ1.dst_transition).to be_nil

        # 2026-03-07: EST
        occ2 = result.occurrences[1]
        expect(occ2.timezone_abbr).to eq('EST')
        expect(occ2.dst?).to be(false)

        # 2026-03-08: Spring Forward! Clocks skip from 02:00 to 03:00.
        # 02:30 is shifted to 03:30 in EDT (-04:00)
        occ3 = result.occurrences[2]
        expect(occ3.timezone_abbr).to eq('EDT')
        expect(occ3.utc_offset).to eq('-04:00')
        expect(occ3.dst?).to be(true)
        expect(occ3.local_iso8601).to eq('2026-03-08T03:30:00-04:00')

        # Check DST transition detection
        expect(occ3.dst_transition).not_to be_nil
        expect(occ3.dst_transition.type).to eq(:spring_forward)
        expect(occ3.dst_transition.from_abbr).to eq('EST')
        expect(occ3.dst_transition.to_abbr).to eq('EDT')
        expect(occ3.dst_transition.from_offset).to eq('-05:00')
        expect(occ3.dst_transition.to_offset).to eq('-04:00')

        # Check shift notice for the skipped hour
        expect(occ3.shift_notice).to include('skipped due to DST spring forward')
        expect(occ3.shift_notice).to include('03:30:00')

        # 2026-03-09: Normal EDT (back to scheduled 02:30)
        occ4 = result.occurrences[3]
        expect(occ4.timezone_abbr).to eq('EDT')
        expect(occ4.dst?).to be(true)
        expect(occ4.local_iso8601).to eq('2026-03-09T02:30:00-04:00')
        expect(occ4.dst_transition).to be_nil

        # Summary transitions list
        expect(result.dst_transitions.size).to eq(1)
        expect(result.dst_transitions.first.type).to eq(:spring_forward)
      end
    end

    context 'with DST fall back transition in America/New_York' do
      # 2026-11-01: 01:00-02:00 repeats (EDT -> EST)
      let(:from_before_fall_back) { Time.utc(2026, 10, 30, 0, 0, 0) }
      let(:schedule) do
        Veltrunode::Model::Schedule.new(
          name: 'dst-fall-test',
          target_function: 'cleaner',
          expression_type: :cron,
          expression: 'cron(30 1 * * ? *)', # 01:30 daily
          timezone: 'America/New_York'
        )
      end

      it 'detects DST fall back transition correctly' do
        result = described_class.preview(schedule, count: 4, from_time: from_before_fall_back)

        expect(result.occurrences.size).to eq(4)

        # Oct 30 & 31: EDT
        expect(result.occurrences[0].timezone_abbr).to eq('EDT')
        expect(result.occurrences[0].dst?).to be(true)
        expect(result.occurrences[1].timezone_abbr).to eq('EDT')

        # Nov 1: EDT occurrence picked first (earlier occurrence during ambiguous hour)
        expect(result.occurrences[2].timezone_abbr).to eq('EDT')

        # Nov 2: EST (-05:00)
        occ4 = result.occurrences[3]
        expect(occ4.timezone_abbr).to eq('EST')
        expect(occ4.utc_offset).to eq('-05:00')
        expect(occ4.dst?).to be(false)

        # Check DST transition detection
        expect(occ4.dst_transition).not_to be_nil
        expect(occ4.dst_transition.type).to eq(:fall_back)
        expect(occ4.dst_transition.from_abbr).to eq('EDT')
        expect(occ4.dst_transition.to_abbr).to eq('EST')

        expect(result.dst_transitions.size).to eq(1)
        expect(result.dst_transitions.first.type).to eq(:fall_back)
      end
    end

    context 'to_h conversion for JSON output' do
      let(:schedule) do
        {
          name: 'json-test',
          target_function: 'my_target',
          expression: 'rate(1 hour)',
          timezone: 'UTC'
        }
      end

      it 'generates a full structured hash' do
        result = described_class.preview(schedule, count: 2, from_time: base_time)
        hash = result.to_h

        expect(hash['schedule_name']).to eq('json-test')
        expect(hash['target_function']).to eq('my_target')
        expect(hash['expression']).to eq('rate(1 hour)')
        expect(hash['expression_type']).to eq('rate')
        expect(hash['timezone']).to eq('UTC')
        expect(hash['count']).to eq(2)
        expect(hash['from_time']).to eq('2026-04-01T00:00:00Z')
        expect(hash['occurrences'].size).to eq(2)
        expect(hash['disclaimer']).to be_a(String)
      end
    end

    context 'error handling' do
      it 'raises ScheduleExpressionError when expression is invalid' do
        invalid_schedule = {
          name: 'bad-expr',
          expression: 'cron(invalid expr)',
          timezone: 'UTC'
        }

        expect do
          described_class.preview(invalid_schedule)
        end.to raise_error(Veltrunode::Scheduler::ScheduleExpressionError)
      end
    end
  end
end
