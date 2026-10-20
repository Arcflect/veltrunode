# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function'

RSpec.describe 'Function Tracing Configuration in Model' do
  it 'supports active tracing with symbol' do
    fn = Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'app.handler',
      runtime: 'nodejs20.x',
      tracing: :active
    )

    expect(fn.tracing_enabled?).to be true
    expect(fn.active_tracing?).to be true
    expect(fn.pass_through_tracing?).to be false
    expect(fn.tracing_mode).to eq('Active')
    expect(fn.adot_enabled?).to be false
  end

  it 'supports pass_through tracing with symbol' do
    fn = Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'app.handler',
      runtime: 'python3.12',
      tracing: :pass_through
    )

    expect(fn.tracing_enabled?).to be true
    expect(fn.active_tracing?).to be false
    expect(fn.pass_through_tracing?).to be true
    expect(fn.tracing_mode).to eq('PassThrough')
    expect(fn.adot_enabled?).to be false
  end

  it 'supports adot tracing shorthand' do
    fn = Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'app.handler',
      runtime: 'nodejs20.x',
      tracing: :adot
    )

    expect(fn.tracing_enabled?).to be true
    expect(fn.active_tracing?).to be true
    expect(fn.tracing_mode).to eq('Active')
    expect(fn.adot_enabled?).to be true
    expect(fn.adot_layer_arn).to be_nil
  end

  it 'supports hash syntax with custom adot layer' do
    custom_arn = 'arn:aws:lambda:ap-northeast-1:123456789012:layer:custom-otel:1'
    fn = Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      tracing: { mode: :active, adot: custom_arn }
    )

    expect(fn.tracing_enabled?).to be true
    expect(fn.active_tracing?).to be true
    expect(fn.adot_enabled?).to be true
    expect(fn.adot_layer_arn).to eq(custom_arn)
  end

  it 'supports disabling tracing' do
    fn = Veltrunode::Model::Function.new(
      logical_name: 'worker',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      tracing: :disabled
    )

    expect(fn.tracing_enabled?).to be false
    expect(fn.tracing_mode).to be_nil
  end

  it 'raises ValidationError for unsupported tracing mode' do
    expect do
      Veltrunode::Model::Function.new(
        logical_name: 'worker',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        tracing: :unknown_mode
      )
    end.to raise_error(Veltrunode::ValidationError, /Unsupported tracing mode/)
  end
end
