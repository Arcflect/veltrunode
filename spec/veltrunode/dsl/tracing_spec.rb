# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'Tracing DSL support' do
  it 'configures tracing inside function block' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "tracing-app" do
        aws region: "ap-northeast-1"

        function :worker do
          handler "app.handler"
          runtime "nodejs20.x"
          tracing :active
        end

        function :reader do
          handler "reader.handler"
          runtime "python3.12"
          tracing :pass_through
        end
      end
    RUBY

    worker = app.functions.find { |f| f.logical_name == 'worker' }
    reader = app.functions.find { |f| f.logical_name == 'reader' }

    expect(worker.tracing_mode).to eq('Active')
    expect(worker.active_tracing?).to be true
    expect(reader.tracing_mode).to eq('PassThrough')
    expect(reader.pass_through_tracing?).to be true
  end

  it 'inherits tracing from defaults and allows override' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "tracing-app" do
        aws region: "ap-northeast-1"

        defaults do
          tracing :active
        end

        function :inherited do
          handler "app.handler"
          runtime "ruby3.3"
        end

        function :overridden do
          handler "app.handler"
          runtime "ruby3.3"
          tracing :pass_through
        end
      end
    RUBY

    inherited_fn = app.functions.find { |f| f.logical_name == 'inherited' }
    overridden_fn = app.functions.find { |f| f.logical_name == 'overridden' }

    expect(inherited_fn.tracing_mode).to eq('Active')
    expect(overridden_fn.tracing_mode).to eq('PassThrough')
  end

  it 'supports adot in function block' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "adot-app" do
        aws region: "ap-northeast-1"

        function :telemetry do
          handler "app.handler"
          runtime "nodejs20.x"
          tracing :adot
        end
      end
    RUBY

    fn = app.functions.find { |f| f.logical_name == 'telemetry' }
    expect(fn.tracing_mode).to eq('Active')
    expect(fn.adot_enabled?).to be true
  end
end
