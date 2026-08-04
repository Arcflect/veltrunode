# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::Capability do
  describe '#initialize' do
    it 'assigns type and params' do
      cap = described_class.new(type: :read_from_s3, params: { bucket: 'my-bucket' })
      expect(cap.type).to eq(:read_from_s3)
      expect(cap.params).to eq({ bucket: 'my-bucket' })
    end

    it 'freezes the instance and params' do
      cap = described_class.new(type: :read_from_s3, params: { bucket: 'my-bucket' })
      expect(cap).to be_frozen
      expect(cap.params).to be_frozen
      expect { cap.params[:bucket] = 'other' }.to raise_error(FrozenError)
    end

    it 'raises ValidationError when type is missing or empty' do
      expect { described_class.new(type: nil) }.to raise_error(Veltrunode::ValidationError, /type/)
      expect { described_class.new(type: '') }.to raise_error(Veltrunode::ValidationError, /type/)
    end
  end
end
