# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/scheduler/errors'

RSpec.describe Veltrunode::Scheduler::ScheduleExpressionError do
  it 'generates a VLT-SCHED-001 diagnostic by default' do
    error = described_class.new(
      "Invalid rate expression 'rate(0 minutes)'",
      expression: 'rate(0 minutes)',
      reason: 'value_must_be_greater_than_zero'
    )

    expect(error.message).to eq("Invalid rate expression 'rate(0 minutes)'")
    expect(error.expression).to eq('rate(0 minutes)')
    expect(error.reason).to eq('value_must_be_greater_than_zero')

    expect(error.diagnostics.length).to eq(1)
    diag = error.diagnostics.first
    expect(diag.code).to eq('VLT-SCHED-001')
    expect(diag.severity).to eq(:error)
    expect(diag.summary).to eq("Invalid rate expression 'rate(0 minutes)'")
    expect(diag.evidence['expression']).to eq('rate(0 minutes)')
    expect(diag.evidence['reason']).to eq('value_must_be_greater_than_zero')
  end
end
