# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function_url'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::Model::FunctionUrl do
  describe '.from and #initialize' do
    it 'supports auth_type: :none with CORS configuration' do
      url = described_class.from(
        auth_type: :none,
        cors: {
          allow_origins: ['https://example.com'],
          allow_methods: %w[GET POST],
          allow_headers: %w[Content-Type Authorization],
          max_age: 3600,
          allow_credentials: true
        }
      )

      expect(url.auth_type).to eq('NONE')
      expect(url.public_access?).to be(true)
      expect(url.iam_auth?).to be(false)
      expect(url.cors?).to be(true)
      expect(url.cors.allow_origins).to eq(['https://example.com'])
      expect(url.cors.allow_methods).to eq(%w[GET POST])
      expect(url.cors.allow_headers).to eq(%w[Content-Type Authorization])
      expect(url.cors.max_age).to eq(3600)
      expect(url.cors.allow_credentials).to be(true)
    end

    it 'supports auth_type: :aws_iam (:iam alias) and invoke_mode' do
      url = described_class.new(auth_type: :aws_iam, invoke_mode: :response_stream, qualifier: 'live')
      expect(url.auth_type).to eq('AWS_IAM')
      expect(url.public_access?).to be(false)
      expect(url.iam_auth?).to be(true)
      expect(url.invoke_mode).to eq('RESPONSE_STREAM')
      expect(url.qualifier).to eq('live')

      iam_short = described_class.from(:iam)
      expect(iam_short.auth_type).to eq('AWS_IAM')
    end

    it 'returns nil when disabled (false or nil)' do
      expect(described_class.from(nil)).to be_nil
      expect(described_class.from(false)).to be_nil
      expect(described_class.from(enabled: false)).to be_nil
    end

    it 'raises ArgumentError for invalid auth_type or invoke_mode' do
      expect { described_class.new(auth_type: :custom) }.to raise_error(
        ArgumentError,
        /Invalid function_url auth_type/
      )
      expect { described_class.new(invoke_mode: :invalid) }.to raise_error(
        ArgumentError,
        /Invalid function_url invoke_mode/
      )
    end
  end

  describe 'Function#function_url integration' do
    it 'normalizes function_url in Veltrunode::Model::Function' do
      fn = Veltrunode::Model::Function.new(
        :webhook,
        handler: 'webhook.handler',
        runtime: 'ruby3.3',
        function_url: { auth_type: :none, cors: true }
      )

      expect(fn.function_url?).to be(true)
      expect(fn.function_url.auth_type).to eq('NONE')
      expect(fn.function_url.cors?).to be(true)
    end
  end
end
