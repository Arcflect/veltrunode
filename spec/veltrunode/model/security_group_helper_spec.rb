# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/security_group_helper'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Model::SecurityGroupHelper do
  let(:valid_vpc_id) { 'vpc-0123456789abcdef0' }
  let(:valid_attributes) do
    {
      symbolic_name: :shared_data,
      vpc_id: valid_vpc_id,
      description: 'Custom SG description',
      tags: { 'Environment' => 'test' }
    }
  end

  describe '#initialize' do
    context 'with valid attributes' do
      subject(:helper) { described_class.new(**valid_attributes) }

      it 'correctly assigns all attributes' do
        expect(helper.symbolic_name).to eq(:shared_data)
        expect(helper.vpc_id).to eq(valid_vpc_id)
        expect(helper.description).to eq('Custom SG description')
        expect(helper.tags).to eq({ 'Environment' => 'test' })
      end

      it 'defaults symbolic_name to :default when not provided' do
        minimal = described_class.new(vpc_id: valid_vpc_id)
        expect(minimal.symbolic_name).to eq(:default)
        expect(minimal.description).to be_nil
        expect(minimal.tags).to eq({})
      end

      it 'accepts Reference as vpc_id' do
        ref = Veltrunode::DSL::Reference.new(:vpc_id)
        helper_with_ref = described_class.new(vpc_id: ref)
        expect(helper_with_ref.vpc_id).to eq(ref)
      end

      it 'accepts Hash as vpc_id (CloudFormation intrinsic functions)' do
        fn_ref = { 'Ref' => 'VpcId' }
        helper_with_hash = described_class.new(vpc_id: fn_ref)
        expect(helper_with_hash.vpc_id).to eq(fn_ref)
      end

      it 'accepts Symbol as vpc_id' do
        helper_with_sym = described_class.new(vpc_id: :vpc_id)
        expect(helper_with_sym.vpc_id).to eq(:vpc_id)
      end
    end

    context 'immutability' do
      subject(:helper) { described_class.new(**valid_attributes) }

      it 'freezes the instance and its structures' do
        expect(helper).to be_frozen
        expect(helper.tags).to be_frozen
      end

      it 'prevents modification of tags' do
        expect { helper.tags['New'] = 'val' }.to raise_error(FrozenError)
      end
    end

    context 'validations' do
      it 'raises ValidationError when vpc_id is nil' do
        expect do
          described_class.new(vpc_id: nil)
        end.to raise_error(Veltrunode::ValidationError, /SecurityGroupHelper vpc_id is required/)
      end

      it 'raises ValidationError when vpc_id is empty string' do
        expect do
          described_class.new(vpc_id: '   ')
        end.to raise_error(Veltrunode::ValidationError, /SecurityGroupHelper vpc_id is required/)
      end

      it 'raises ValidationError when symbolic_name is empty string' do
        expect do
          described_class.new(symbolic_name: '', vpc_id: valid_vpc_id)
        end.to raise_error(Veltrunode::ValidationError, /SecurityGroupHelper symbolic_name is required/)
      end
    end
  end
end
