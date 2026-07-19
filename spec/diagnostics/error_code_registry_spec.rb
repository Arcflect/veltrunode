# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Diagnostics::ErrorCodeRegistry do
  describe 'CATEGORY_PREFIXES' do
    it 'defines all supported VLT code categories' do
      expect(described_class::CATEGORY_PREFIXES).to contain_exactly(
        'VLT-DSL-*',
        'VLT-REF-*',
        'VLT-GRAPH-*',
        'VLT-BUILD-*',
        'VLT-LAYER-*',
        'VLT-SCHED-*',
        'VLT-EFS-*',
        'VLT-AWS-*',
        'VLT-IAM-*',
        'VLT-CFN-*'
      )
    end
  end

  describe '.valid?' do
    it 'accepts valid persistent diagnostic code formats' do
      expect(described_class.valid?('VLT-DSL-001')).to be(true)
      expect(described_class.valid?('VLT-EFS-2049-INGRESS')).to be(true)
      expect(described_class.valid?('VLT-AWS-ACCOUNT-001')).to be(true)
    end

    it 'rejects invalid code formats' do
      expect(described_class.valid?('DSL-001')).to be(false)
      expect(described_class.valid?('VLT-UNKNOWN-001')).to be(false)
      expect(described_class.valid?('VLT-REF-')).to be(false)
    end
  end

  describe '.build' do
    it 'builds a normalized code from category and identifier' do
      expect(described_class.build(:dsl, '001')).to eq('VLT-DSL-001')
      expect(described_class.build('efs', '2049-ingress')).to eq('VLT-EFS-2049-INGRESS')
    end
  end
end
