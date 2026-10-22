# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/dashboard_builder'
require 'veltrunode/dsl/application_builder'

RSpec.describe Veltrunode::DSL::DashboardBuilder do
  describe '#build' do
    it 'creates a default dashboard model' do
      builder = described_class.new
      dashboard = builder.build

      expect(dashboard.name).to eq('default')
      expect(dashboard.period).to eq(300)
      expect(dashboard.widgets.size).to eq(4)
    end

    it 'supports block configuration with custom period and widgets' do
      builder = described_class.new(:custom)
      builder.instance_eval do
        title 'My Custom Dashboard'
        period 60
        invocations stat: 'Sum', period: 60
        errors stat: 'Sum'
        duration stat: 'p95'
        concurrent_executions
      end

      dashboard = builder.build
      expect(dashboard.name).to eq('custom')
      expect(dashboard.title).to eq('My Custom Dashboard')
      expect(dashboard.period).to eq(60)
      expect(dashboard.widgets.size).to eq(4)
      expect(dashboard.widgets[0].stat).to eq('Sum')
      expect(dashboard.widgets[2].stat).to eq('p95')
    end
  end

  describe 'ApplicationBuilder integration' do
    it 'supports dashboard true' do
      app_builder = Veltrunode::DSL::ApplicationBuilder.new('test-app')
      app_builder.dashboard true
      app = app_builder.build

      expect(app.dashboard).not_to be_nil
      expect(app.dashboard.enabled?).to be true
      expect(app.dashboard.name).to eq('default')
      expect(app.dashboard.widgets.size).to eq(4)
    end

    it 'supports dashboard with name and block' do
      app_builder = Veltrunode::DSL::ApplicationBuilder.new('test-app')
      app_builder.dashboard :overview do
        title 'Operations Overview'
        period 60
        widgets :invocations, :errors
      end
      app = app_builder.build

      expect(app.dashboard).not_to be_nil
      expect(app.dashboard.name).to eq('overview')
      expect(app.dashboard.title).to eq('Operations Overview')
      expect(app.dashboard.period).to eq(60)
      expect(app.dashboard.widgets.size).to eq(2)
    end

    it 'supports disabling dashboard with false' do
      app_builder = Veltrunode::DSL::ApplicationBuilder.new('test-app')
      app_builder.dashboard false
      app = app_builder.build

      expect(app.dashboard).to be_nil
    end
  end
end
