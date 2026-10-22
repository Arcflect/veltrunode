# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Dashboard do
  describe '#initialize' do
    context 'with defaults' do
      subject(:dashboard) { described_class.new }

      it 'assigns default attributes' do
        expect(dashboard.name).to eq('default')
        expect(dashboard.period).to eq(300)
        expect(dashboard.title).to be_nil
        expect(dashboard.enabled?).to be true
      end

      it 'generates 4 default widgets' do
        expect(dashboard.widgets.size).to eq(4)
        metrics = dashboard.widgets.map(&:metric)
        expect(metrics).to eq(%w[invocations errors duration concurrent_executions])

        invocations = dashboard.widgets[0]
        expect(invocations.title).to eq('Invocations')
        expect(invocations.stat).to eq('Sum')
        expect(invocations.period).to eq(300)
        expect(invocations.width).to eq(12)
        expect(invocations.height).to eq(6)
        expect(invocations.x).to eq(0)
        expect(invocations.y).to eq(0)

        errors = dashboard.widgets[1]
        expect(errors.title).to eq('Errors')
        expect(errors.stat).to eq('Sum')
        expect(errors.x).to eq(12)
        expect(errors.y).to eq(0)

        duration = dashboard.widgets[2]
        expect(duration.title).to eq('Duration')
        expect(duration.stat).to eq('Average')
        expect(duration.x).to eq(0)
        expect(duration.y).to eq(6)

        concurrency = dashboard.widgets[3]
        expect(concurrency.title).to eq('Concurrent Executions')
        expect(concurrency.stat).to eq('Maximum')
        expect(concurrency.x).to eq(12)
        expect(concurrency.y).to eq(6)
      end

      it 'is frozen' do
        expect(dashboard).to be_frozen
        expect(dashboard.widgets).to be_frozen
        expect(dashboard.widgets.first).to be_frozen
      end
    end

    context 'with custom attributes' do
      subject(:dashboard) do
        described_class.new(
          name: :monitoring,
          title: 'System Overview',
          period: 60,
          widgets: [
            { metric: :invocations, stat: 'Sum', period: 60 },
            { metric: :errors, stat: 'Sum', period: 60 }
          ]
        )
      end

      it 'assigns custom attributes' do
        expect(dashboard.name).to eq('monitoring')
        expect(dashboard.title).to eq('System Overview')
        expect(dashboard.period).to eq(60)
        expect(dashboard.widgets.size).to eq(2)
        expect(dashboard.widgets[0].metric).to eq('invocations')
        expect(dashboard.widgets[1].metric).to eq('errors')
      end
    end

    context 'validation errors' do
      it 'raises error when name is blank' do
        expect do
          described_class.new(name: '')
        end.to raise_error(Veltrunode::ValidationError, /Dashboard name is required/)
      end

      it 'raises error when period is less than 10 or not a multiple of 10' do
        expect do
          described_class.new(period: 5)
        end.to raise_error(Veltrunode::ValidationError, /Invalid dashboard period/)

        expect do
          described_class.new(period: 25)
        end.to raise_error(Veltrunode::ValidationError, /Invalid dashboard period/)
      end

      it 'raises error when widget width is out of range' do
        expect do
          described_class::Widget.new(metric: :invocations, width: 25)
        end.to raise_error(Veltrunode::ValidationError, /Invalid widget width/)
      end

      it 'raises error when widget height is out of range' do
        expect do
          described_class::Widget.new(metric: :invocations, height: 0)
        end.to raise_error(Veltrunode::ValidationError, /Invalid widget height/)
      end

      it 'raises error when widget coordinates are negative' do
        expect do
          described_class::Widget.new(metric: :invocations, x: -1)
        end.to raise_error(Veltrunode::ValidationError, /Invalid widget x coordinate/)
      end
    end

    describe '#to_h' do
      it 'serializes to hash' do
        dashboard = described_class.new(name: 'main', period: 60)
        hash = dashboard.to_h

        expect(hash['name']).to eq('main')
        expect(hash['period']).to eq(60)
        expect(hash['enabled']).to be true
        expect(hash['widgets']).to be_an(Array)
        expect(hash['widgets'].size).to eq(4)
      end
    end
  end
end
