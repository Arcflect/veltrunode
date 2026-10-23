# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'Insights DSL support' do
  it 'configures insights inside function block' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "insights-app" do
        aws region: "ap-northeast-1"

        function :worker do
          handler "app.handler"
          runtime "nodejs20.x"
          insights true
        end

        function :reader do
          handler "reader.handler"
          runtime "python3.12"
          insights false
        end

        function :custom_ver do
          handler "custom.handler"
          runtime "ruby3.3"
          insights version: 50
        end

        function :custom_layer do
          handler "custom2.handler"
          runtime "ruby3.3"
          insights layer_arn: "arn:aws:lambda:us-east-1:123456789012:layer:CustomInsights:1"
        end
      end
    RUBY

    worker = app.functions.find { |f| f.logical_name == 'worker' }
    reader = app.functions.find { |f| f.logical_name == 'reader' }
    custom_ver = app.functions.find { |f| f.logical_name == 'custom_ver' }
    custom_layer = app.functions.find { |f| f.logical_name == 'custom_layer' }

    expect(worker.insights_enabled?).to be true
    expect(reader.insights_enabled?).to be false
    expect(custom_ver.insights_enabled?).to be true
    expect(custom_ver.insights_version).to eq(50)
    expect(custom_layer.insights_enabled?).to be true
    expect(custom_layer.insights_layer_arn).to eq('arn:aws:lambda:us-east-1:123456789012:layer:CustomInsights:1')
  end

  it 'supports insights as function kwargs' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "insights-kw-app" do
        aws region: "ap-northeast-1"

        function :worker, insights: true do
          handler "app.handler"
          runtime "nodejs20.x"
        end
      end
    RUBY

    worker = app.functions.find { |f| f.logical_name == 'worker' }
    expect(worker.insights_enabled?).to be true
  end

  it 'inherits insights from defaults and allows override' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "insights-defaults-app" do
        aws region: "ap-northeast-1"

        defaults do
          insights true
        end

        function :inherited do
          handler "app.handler"
          runtime "ruby3.3"
        end

        function :overridden do
          handler "app.handler"
          runtime "ruby3.3"
          insights false
        end
      end
    RUBY

    inherited_fn = app.functions.find { |f| f.logical_name == 'inherited' }
    overridden_fn = app.functions.find { |f| f.logical_name == 'overridden' }

    expect(inherited_fn.insights_enabled?).to be true
    expect(overridden_fn.insights_enabled?).to be false
  end
end
