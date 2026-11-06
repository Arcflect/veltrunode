# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode'

RSpec.describe 'Function URL DSL' do
  it 'parses function_url keyword argument and block syntax with auth_type and cors' do
    code = <<~RUBY
      Veltrunode.application "webhook-app" do
        aws region: "ap-northeast-1"

        function :webhook, function_url: {
          auth_type: :none,
          cors: {
            allow_origins: ["https://example.com"],
            allow_methods: ["POST", "OPTIONS"],
            allow_headers: ["Content-Type", "X-Signature"],
            max_age: 86400
          }
        } do
          handler "webhook.handler"
          runtime "ruby3.3"
        end

        function :internal_api do
          handler "internal.handler"
          runtime "ruby3.3"
          function_url do
            auth_type :aws_iam
            invoke_mode :response_stream
            cors do
              origins "https://internal.example.com"
              methods "GET", "POST"
              allow_credentials true
            end
          end
        end
      end
    RUBY

    app = Veltrunode.parse(code)

    webhook = app.functions['webhook']
    expect(webhook.function_url?).to be(true)
    expect(webhook.function_url.auth_type).to eq('NONE')
    expect(webhook.function_url.public_access?).to be(true)
    expect(webhook.function_url.cors.allow_origins).to eq(['https://example.com'])
    expect(webhook.function_url.cors.allow_methods).to eq(%w[POST OPTIONS])
    expect(webhook.function_url.cors.allow_headers).to eq(%w[Content-Type X-Signature])
    expect(webhook.function_url.cors.max_age).to eq(86_400)

    internal = app.functions['internal_api']
    expect(internal.function_url?).to be(true)
    expect(internal.function_url.auth_type).to eq('AWS_IAM')
    expect(internal.function_url.iam_auth?).to be(true)
    expect(internal.function_url.invoke_mode).to eq('RESPONSE_STREAM')
    expect(internal.function_url.cors.allow_origins).to eq(['https://internal.example.com'])
    expect(internal.function_url.cors.allow_credentials).to be(true)
  end

  it 'supports defaults block inheritance and function-level opt-out (function_url false)' do
    code = <<~RUBY
      Veltrunode.application "defaults-url-app" do
        defaults do
          function_url auth_type: :aws_iam, cors: true
        end

        function :service_a do
          handler "a.handler"
          runtime "ruby3.3"
        end

        function :batch_worker do
          handler "worker.handler"
          runtime "ruby3.3"
          function_url false
        end
      end
    RUBY

    app = Veltrunode.parse(code)

    expect(app.functions['service_a'].function_url?).to be(true)
    expect(app.functions['service_a'].function_url.auth_type).to eq('AWS_IAM')
    expect(app.functions['batch_worker'].function_url?).to be(false)
  end
end
