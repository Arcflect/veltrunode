# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::PolicyPack do
  describe '.production' do
    it 'creates a StagePolicy with all production security rules enabled' do
      policy = described_class.production

      expect(policy.stage).to eq('production')
      expect(policy.pack_name).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(true)
      expect(policy.deny_public_storage?).to be(true)
      expect(policy).to be_frozen
    end

    it 'accepts custom stage name and rule overrides' do
      policy = described_class.production('prod-jp', deny_wildcard_actions: false)

      expect(policy.stage).to eq('prod-jp')
      expect(policy.pack_name).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(false)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(true)
      expect(policy.deny_public_storage?).to be(true)
    end
  end

  describe '.builtin' do
    it 'resolves :production policy pack' do
      policy = described_class.builtin(:production)
      expect(policy.stage).to eq('production')
      expect(policy.pack_name).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
    end

    it 'resolves :prod alias' do
      policy = described_class.builtin('prod', 'staging')
      expect(policy.stage).to eq('staging')
      expect(policy.pack_name).to eq('prod')
      expect(policy.require_log_retention?).to be(true)
    end

    it 'raises ArgumentError for unknown policy pack' do
      expect { described_class.builtin(:unknown) }
        .to raise_error(ArgumentError, /Unknown policy pack 'unknown'/)
    end
  end

  describe '.builtin?' do
    it 'returns true for supported built-in pack names' do
      expect(described_class.builtin?(:production)).to be(true)
      expect(described_class.builtin?('production')).to be(true)
      expect(described_class.builtin?('prod')).to be(true)
      expect(described_class.builtin?('PROD')).to be(true)
    end

    it 'returns false for nil or unknown pack names' do
      expect(described_class.builtin?(nil)).to be(false)
      expect(described_class.builtin?(:custom)).to be(false)
    end
  end

  describe '.available_packs' do
    it 'lists available pack identifiers' do
      expect(described_class.available_packs).to eq([:production])
    end
  end

  describe 'StagePolicy.production_default' do
    it 'creates production StagePolicy via StagePolicy convenience method' do
      policy = Veltrunode::Model::StagePolicy.production_default

      expect(policy.stage).to eq('production')
      expect(policy.pack_name).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(true)
      expect(policy.deny_public_storage?).to be(true)
    end
  end
end
