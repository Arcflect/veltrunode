# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/secret_value'

RSpec.describe Veltrunode::DSL::SecretValue do
  before do
    described_class.clear_registry!
  end

  after do
    described_class.clear_registry!
  end

  describe '.register and .registry' do
    it 'registers secret values automatically upon initialization' do
      secret = described_class.new('my_secret_token')

      expect(described_class.registry).to include('my_secret_token')
      expect(secret.raw_value).to eq('my_secret_token')
      expect(secret.to_s).to eq('my_secret_token')
      expect(secret.inspect).to eq('[FILTERED]')
      expect(secret.secret?).to be true
    end

    it 'ignores empty strings from registry' do
      described_class.new('')

      expect(described_class.registry).to be_empty
    end

    it 'clears registry with .clear_registry!' do
      described_class.new('token1')
      described_class.new('token2')
      expect(described_class.registry.size).to eq(2)

      described_class.clear_registry!
      expect(described_class.registry).to be_empty
    end
  end
end
