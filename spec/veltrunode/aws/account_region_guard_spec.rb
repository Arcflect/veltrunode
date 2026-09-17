# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/aws/account_region_guard'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::AWS::AccountRegionGuard do
  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'guard-app',
      region: 'ap-northeast-1',
      stage: 'production',
      account_constraint: '123456789012'
    )
  end

  let(:mock_caller_identity) do
    double('CallerIdentity', account: '123456789012', arn: 'arn:aws:iam::123456789012:root')
  end

  let(:mock_sts_client) do
    instance_double('Aws::STS::Client', get_caller_identity: mock_caller_identity)
  end

  describe '.check' do
    it 'returns empty errors when account and region match' do
      diagnostics = described_class.check(application, sts_client: mock_sts_client, aws_region: 'ap-northeast-1')
      errors = diagnostics.select { |d| d.severity == :error }

      expect(errors).to be_empty
    end

    it 'returns account mismatch error when accounts differ' do
      diff_identity = double('CallerIdentity', account: '999999999999')
      diff_client = instance_double('Aws::STS::Client', get_caller_identity: diff_identity)

      diagnostics = described_class.check(application, sts_client: diff_client)
      error = diagnostics.find { |d| d.code == 'VLT-AWS-ACCOUNT-001' }

      expect(error).not_to be_nil
      expect(error.severity).to eq(:error)
    end
  end

  describe '.check!' do
    it 'returns diagnostics without error when verification passes' do
      expect do
        described_class.check!(application, sts_client: mock_sts_client, aws_region: 'ap-northeast-1')
      end.not_to raise_error
    end

    it 'raises AccountRegionMismatchError when verification fails' do
      diff_identity = double('CallerIdentity', account: '999999999999')
      diff_client = instance_double('Aws::STS::Client', get_caller_identity: diff_identity)

      expect { described_class.check!(application, sts_client: diff_client) }
        .to raise_error(Veltrunode::AWS::AccountRegionMismatchError) do |error|
          expect(error.message).to include('AWS account/region verification failed')
          expect(error.diagnostics.any? { |d| d.code == 'VLT-AWS-ACCOUNT-001' }).to be(true)
        end
    end
  end
end
