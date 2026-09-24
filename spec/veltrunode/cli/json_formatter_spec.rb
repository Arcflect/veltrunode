# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'veltrunode/cli/json_formatter'
require 'veltrunode/dsl/secret_value'
require 'veltrunode/diagnostics/diagnostic'

RSpec.describe Veltrunode::CLI::JsonFormatter do
  before do
    Veltrunode::DSL::SecretValue.clear_registry!
  end

  after do
    Veltrunode::DSL::SecretValue.clear_registry!
  end

  describe '.format' do
    it 'formats output matching common schema' do
      json_str = described_class.format(
        command: 'deploy',
        status: 'success',
        diagnostics: [],
        data: { 'stack_name' => 'my-stack', 'version' => '1.0.0' }
      )

      parsed = JSON.parse(json_str)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('deploy')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics']).to eq([])
      expect(parsed['data']).to eq({ 'stack_name' => 'my-stack', 'version' => '1.0.0' })
    end

    it 'formats diagnostics properly when given Diagnostic objects' do
      diag = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-BUILD-001',
        severity: :warning,
        summary: 'Warning summary',
        suggested_action: 'Check configuration'
      )

      json_str = described_class.format(
        command: 'validate',
        status: 'success',
        diagnostics: [diag],
        data: { 'errors_count' => 0 }
      )

      parsed = JSON.parse(json_str)
      expect(parsed['diagnostics'].size).to eq(1)
      expect(parsed['diagnostics'].first['code']).to eq('VLT-BUILD-001')
      expect(parsed['diagnostics'].first['severity']).to eq('warning')
    end

    it 'automatically masks SecretValue instances in data' do
      secret = Veltrunode::DSL::SecretValue.new('top_secret_token_12345')

      json_str = described_class.format(
        command: 'plan',
        status: 'success',
        data: {
          'env' => {
            'API_KEY' => secret,
            'PUBLIC_URL' => 'https://example.com'
          }
        }
      )

      parsed = JSON.parse(json_str)
      expect(parsed['data']['env']['API_KEY']).to eq('[FILTERED]')
      expect(parsed['data']['env']['PUBLIC_URL']).to eq('https://example.com')
      expect(json_str).not_to include('top_secret_token_12345')
    end

    it 'automatically masks registered secret text in strings' do
      Veltrunode::DSL::SecretValue.new('my-db-password-xyz')

      json_str = described_class.format(
        command: 'invoke local',
        status: 'error',
        data: {
          'message' => 'Connection failed with password my-db-password-xyz at localhost'
        }
      )

      parsed = JSON.parse(json_str)
      expect(parsed['data']['message']).to eq('Connection failed with password [FILTERED] at localhost')
      expect(json_str).not_to include('my-db-password-xyz')
    end

    it 'produces JSON parseable by jq' do
      json_str = described_class.format(
        command: 'build',
        status: 'success',
        diagnostics: [],
        data: { 'artifacts' => %w[fn1.zip layer1.zip] }
      )

      stdout, stderr, status = Open3.capture3('jq .', stdin_data: json_str)
      expect(status.success?).to be true
      expect(stderr).to be_empty
      expect(stdout).to include('"command": "build"')
    end
  end
end
