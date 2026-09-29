# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler'

RSpec.describe Veltrunode::Scheduler::Parser do
  describe '.parse' do
    it 'parses rate expression into RateExpression' do
      expr = described_class.parse('rate(1 hour)')
      expect(expr).to be_a(Veltrunode::Scheduler::RateExpression)
      expect(expr.value).to eq(1)
      expect(expr.unit).to eq('hour')
    end

    it 'parses cron expression into CronExpression' do
      expr = described_class.parse('cron(0 12 * * ? *)')
      expect(expr).to be_a(Veltrunode::Scheduler::CronExpression)
    end

    it 'parses at expression into AtExpression' do
      expr = described_class.parse('at(2026-10-01T15:00:00)')
      expect(expr).to be_a(Veltrunode::Scheduler::AtExpression)
      expect(expr.year).to eq(2026)
    end

    it 'is accessible via Veltrunode::Scheduler.parse' do
      expr = Veltrunode::Scheduler.parse('rate(10 minutes)')
      expect(expr).to be_a(Veltrunode::Scheduler::RateExpression)
    end

    it 'raises ScheduleExpressionError for unknown expression type' do
      expect { described_class.parse('every 5 minutes') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('unknown_schedule_type')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end

    it 'propagates syntax errors with VLT-SCHED-001' do
      expect { described_class.parse('rate(0 minutes)') }
        .to raise_error(Veltrunode::Scheduler::ScheduleExpressionError) do |error|
          expect(error.reason).to eq('value_must_be_greater_than_zero')
          expect(error.diagnostics.first.code).to eq('VLT-SCHED-001')
        end
    end
  end
end
