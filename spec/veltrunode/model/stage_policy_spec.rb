# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::StagePolicy do
  describe '#initialize' do
    it 'creates a frozen StagePolicy with default false values' do
      policy = described_class.new(:production)

      expect(policy.stage).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(false)
      expect(policy.require_dlq?).to be(false)
      expect(policy.require_log_retention?).to be(false)
      expect(policy.deny_public_storage?).to be(false)
      expect(policy).to be_frozen
    end

    it 'accepts positional stage or keyword stage_name' do
      policy1 = described_class.new('staging')
      policy2 = described_class.new(stage_name: 'staging')

      expect(policy1.stage).to eq('staging')
      expect(policy2.stage).to eq('staging')
    end

    it 'allows configuring all policy rules' do
      policy = described_class.new(
        :production,
        deny_wildcard_actions: true,
        require_dlq: true,
        require_log_retention: true,
        deny_public_storage: true
      )

      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(true)
      expect(policy.deny_public_storage?).to be(true)
    end

    it 'raises ValidationError when stage name is missing or empty' do
      expect { described_class.new(nil) }
        .to raise_error(Veltrunode::ValidationError, /stage name is required/)
      expect { described_class.new('') }
        .to raise_error(Veltrunode::ValidationError, /stage name is required/)
    end
  end

  describe '#applies_to?' do
    let(:policy) { described_class.new('production') }
    let(:wildcard_policy) { described_class.new('*') }

    it 'returns true for exact or case-insensitive matching stage' do
      expect(policy.applies_to?('production')).to be(true)
      expect(policy.applies_to?(:production)).to be(true)
      expect(policy.applies_to?('PRODUCTION')).to be(true)
      expect(policy.applies_to?('Production')).to be(true)
    end

    it 'returns false for non-matching stage or nil' do
      expect(policy.applies_to?('dev')).to be(false)
      expect(policy.applies_to?('staging')).to be(false)
      expect(policy.applies_to?(nil)).to be(false)
    end

    it 'wildcard stage policy matches any stage' do
      expect(wildcard_policy.applies_to?('dev')).to be(true)
      expect(wildcard_policy.applies_to?('production')).to be(true)
      expect(wildcard_policy.applies_to?(nil)).to be(false)
    end
  end
end
