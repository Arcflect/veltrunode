# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/aws/inspectors/connection_inspector'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::AWS::Inspectors::ConnectionInspector do
  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'test-app',
      region: 'ap-northeast-1',
      stage: 'prod',
      account_constraint: '123456789012'
    )
  end

  let(:mock_caller_identity) do
    double('CallerIdentity', account: '123456789012', arn: 'arn:aws:iam::123456789012:user/dev',
                             user_id: 'AIDACKCEVSQ6C2EXAMPLE')
  end

  let(:mock_sts_client) do
    instance_double('Aws::STS::Client', get_caller_identity: mock_caller_identity)
  end

  describe '.inspect' do
    it 'returns no diagnostics when STS authentication succeeds and account matches' do
      diagnostics = described_class.inspect(application, sts_client: mock_sts_client)
      errors = diagnostics.select { |d| d.severity == :error }

      expect(errors).to be_empty
    end

    it 'returns no diagnostics when account_constraint is not specified' do
      no_constraint_app = Veltrunode::Model::Application.new(
        name: 'test-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        account_constraint: nil
      )

      diagnostics = described_class.inspect(no_constraint_app, sts_client: mock_sts_client)
      errors = diagnostics.select { |d| d.severity == :error }

      expect(errors).to be_empty
    end

    it 'detects account mismatch and returns VLT-AWS-ACCOUNT-001 error diagnostic' do
      mismatched_identity = double('CallerIdentity', account: '999999999999')
      mismatched_client = instance_double('Aws::STS::Client', get_caller_identity: mismatched_identity)

      diagnostics = described_class.inspect(application, sts_client: mismatched_client)
      account_error = diagnostics.find { |d| d.code == 'VLT-AWS-ACCOUNT-001' }

      expect(account_error).not_to be_nil
      expect(account_error.severity).to eq(:error)
      expect(account_error.summary).to include('AWS account mismatch')
      expect(account_error.evidence['current_account']).to eq('999999999999')
      expect(account_error.evidence['expected_account']).to eq('123456789012')
    end

    it 'detects STS authentication failure and returns VLT-AWS-AUTH-001 error diagnostic' do
      failing_client = instance_double('Aws::STS::Client')
      allow(failing_client).to receive(:get_caller_identity).and_raise(
        RuntimeError, 'The security token included in the request is invalid.'
      )

      diagnostics = described_class.inspect(application, sts_client: failing_client)
      auth_error = diagnostics.find { |d| d.code == 'VLT-AWS-AUTH-001' }

      expect(auth_error).not_to be_nil
      expect(auth_error.severity).to eq(:error)
      expect(auth_error.summary).to include('AWS authentication failed')
      expect(auth_error.evidence['error']).to include('security token')
    end

    it 'handles unavailable STS client by returning VLT-AWS-AUTH-001 diagnostic' do
      inspector = described_class.new(application, sts_client: nil)
      allow(inspector).to receive(:resolve_sts_client).and_return(nil)

      diagnostics = inspector.inspect
      auth_error = diagnostics.find { |d| d.code == 'VLT-AWS-AUTH-001' }

      expect(auth_error).not_to be_nil
      expect(auth_error.severity).to eq(:error)
    end
  end
end
