# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'

RSpec.describe 'AsyncInvoke DSL support' do
  it 'configures async_invoke inside function block' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "async-app" do
        aws region: "ap-northeast-1"

        function :worker do
          handler "app.handler"
          runtime "nodejs20.x"
          async_invoke max_retries: 2, max_age_seconds: 3600
        end

        function :custom_dest do
          handler "dest.handler"
          runtime "ruby3.3"
          async_invoke max_retries: 1,
                       on_success: "arn:aws:sqs:ap-northeast-1:123456789012:success-queue",
                       on_failure: "arn:aws:sns:ap-northeast-1:123456789012:failure-topic"
        end

        function :disabled do
          handler "disabled.handler"
          runtime "python3.12"
          async_invoke false
        end
      end
    RUBY

    worker = app.functions.find { |f| f.logical_name == 'worker' }
    custom_dest = app.functions.find { |f| f.logical_name == 'custom_dest' }
    disabled = app.functions.find { |f| f.logical_name == 'disabled' }

    expect(worker.async_invoke?).to be true
    expect(worker.async_invoke.max_retries).to eq(2)
    expect(worker.async_invoke.max_age).to eq(3600)
    expect(worker.async_invoke.destination_config?).to be false

    expect(custom_dest.async_invoke?).to be true
    expect(custom_dest.async_invoke.max_retries).to eq(1)
    expect(custom_dest.async_invoke.on_success).to eq('arn:aws:sqs:ap-northeast-1:123456789012:success-queue')
    expect(custom_dest.async_invoke.on_failure).to eq('arn:aws:sns:ap-northeast-1:123456789012:failure-topic')

    expect(disabled.async_invoke?).to be false
  end

  it 'supports async_invoke as function kwargs' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "async-kw-app" do
        aws region: "ap-northeast-1"

        function :worker, async_invoke: { max_retries: 0, max_age: 1800 } do
          handler "app.handler"
          runtime "nodejs20.x"
        end
      end
    RUBY

    worker = app.functions.find { |f| f.logical_name == 'worker' }
    expect(worker.async_invoke?).to be true
    expect(worker.async_invoke.max_retries).to eq(0)
    expect(worker.async_invoke.max_age).to eq(1800)
  end

  it 'inherits async_invoke from defaults and allows override' do
    app = Veltrunode.parse <<~RUBY
      Veltrunode.application "async-defaults-app" do
        aws region: "ap-northeast-1"

        defaults do
          async_invoke max_retries: 1, max_age_seconds: 7200
        end

        function :inherited do
          handler "app.handler"
          runtime "ruby3.3"
        end

        function :overridden do
          handler "app.handler"
          runtime "ruby3.3"
          async_invoke max_retries: 2, max_age_seconds: 300
        end

        function :opt_out do
          handler "app.handler"
          runtime "ruby3.3"
          async_invoke false
        end
      end
    RUBY

    inherited_fn = app.functions.find { |f| f.logical_name == 'inherited' }
    overridden_fn = app.functions.find { |f| f.logical_name == 'overridden' }
    opt_out_fn = app.functions.find { |f| f.logical_name == 'opt_out' }

    expect(inherited_fn.async_invoke?).to be true
    expect(inherited_fn.async_invoke.max_retries).to eq(1)
    expect(inherited_fn.async_invoke.max_age).to eq(7200)

    expect(overridden_fn.async_invoke?).to be true
    expect(overridden_fn.async_invoke.max_retries).to eq(2)
    expect(overridden_fn.async_invoke.max_age).to eq(300)

    expect(opt_out_fn.async_invoke?).to be false
  end
end
