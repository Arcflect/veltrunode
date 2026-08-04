# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Model::CapabilityExpander do
  let(:context) { { region: 'ap-northeast-1', account: '123456789012', stage: 'dev' } }
  let(:expander) { described_class.new(context) }

  it 'defines MAPPING_VERSION' do
    expect(described_class::MAPPING_VERSION).to eq('1.0.0')
  end

  describe '#expand' do
    context 'read_from_s3 capability' do
      it 'expands into GetObject and ListBucket with specific ARNs' do
        cap = Veltrunode::Model::Capability.new(
          type: :read_from_s3,
          params: { bucket: 'my-data-bucket', prefix: 'app/' }
        )
        statements = expander.expand(cap)

        expect(statements.size).to eq(1)
        stmt = statements.first
        expect(stmt['Effect']).to eq('Allow')
        expect(stmt['Action']).to eq(['s3:GetObject', 's3:ListBucket'])
        expect(stmt['Resource']).to eq(['arn:aws:s3:::my-data-bucket', 'arn:aws:s3:::my-data-bucket/app/*'])
      end

      it 'raises ValidationError when bucket parameter is missing' do
        cap = Veltrunode::Model::Capability.new(type: :read_from_s3, params: {})
        expect { expander.expand(cap) }.to raise_error(Veltrunode::ValidationError, /bucket/)
      end
    end

    context 'write_to_s3 capability' do
      it 'expands into PutObject with specific ARN' do
        cap = Veltrunode::Model::Capability.new(
          type: :write_to_s3,
          params: { bucket: 'my-out-bucket', prefix: 'logs/' }
        )
        statements = expander.expand(cap)

        expect(statements.size).to eq(1)
        stmt = statements.first
        expect(stmt['Effect']).to eq('Allow')
        expect(stmt['Action']).to eq(['s3:PutObject'])
        expect(stmt['Resource']).to eq(['arn:aws:s3:::my-out-bucket/logs/*'])
      end

      it 'raises ValidationError when bucket parameter is missing' do
        cap = Veltrunode::Model::Capability.new(type: :write_to_s3, params: {})
        expect { expander.expand(cap) }.to raise_error(Veltrunode::ValidationError, /bucket/)
      end
    end

    context 'read_parameter capability' do
      it 'expands into GetParameter and GetParameters with specific SSM ARN' do
        cap = Veltrunode::Model::Capability.new(
          type: :read_parameter,
          params: { name: '/config/db/password' }
        )
        statements = expander.expand(cap)

        expect(statements.size).to eq(1)
        stmt = statements.first
        expect(stmt['Effect']).to eq('Allow')
        expect(stmt['Action']).to eq(['ssm:GetParameter', 'ssm:GetParameters'])
        expect(stmt['Resource']).to eq(['arn:aws:ssm:ap-northeast-1:123456789012:parameter/config/db/password'])
      end

      it 'raises ValidationError when name/path parameter is missing' do
        cap = Veltrunode::Model::Capability.new(type: :read_parameter, params: {})
        expect { expander.expand(cap) }.to raise_error(Veltrunode::ValidationError, /name or path/)
      end
    end

    context 'custom IAM capability' do
      it 'expands explicit IAM actions and resources directly' do
        cap = Veltrunode::Model::Capability.new(
          type: :custom,
          params: {
            actions: ['sqs:SendMessage', 'sqs:ReceiveMessage'],
            resources: ['arn:aws:sqs:ap-northeast-1:123456789012:my-queue']
          }
        )
        statements = expander.expand(cap)

        expect(statements.size).to eq(1)
        stmt = statements.first
        expect(stmt['Effect']).to eq('Allow')
        expect(stmt['Action']).to eq(['sqs:SendMessage', 'sqs:ReceiveMessage'])
        expect(stmt['Resource']).to eq(['arn:aws:sqs:ap-northeast-1:123456789012:my-queue'])
      end
    end

    context 'wildcard and stage policy enforcement' do
      it 'emits warning diagnostics in dev stage for wildcard resources' do
        dev_expander = described_class.new(context.merge(stage: 'dev'))
        cap = Veltrunode::Model::Capability.new(
          type: :custom,
          params: { actions: ['s3:GetObject'], resources: ['*'] }
        )

        statements = dev_expander.expand(cap)
        expect(statements.size).to eq(1)

        diagnostics = dev_expander.check_wildcards(statements)
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.severity).to eq(:warning)
      end

      it 'raises ValidationError in prod stage for wildcard actions or resources' do
        prod_expander = described_class.new(context.merge(stage: 'prod'))
        cap = Veltrunode::Model::Capability.new(
          type: :custom,
          params: { actions: ['s3:GetObject'], resources: ['*'] }
        )

        expect { prod_expander.expand(cap) }
          .to raise_error(Veltrunode::ValidationError) { |err|
            expect(err.diagnostics).not_to be_empty
            expect(err.diagnostics.first.code).to eq('VLT-IAM-WILDCARD-RESOURCE')
          }
      end

      it 'raises ValidationError in prod stage when expanded ARN contains wildcard region or account' do
        prod_expander_without_context = described_class.new(stage: 'prod')
        cap = Veltrunode::Model::Capability.new(
          type: :read_parameter,
          params: { name: '/config/db' }
        )

        expect { prod_expander_without_context.expand(cap) }
          .to raise_error(Veltrunode::ValidationError) { |err|
            expect(err.diagnostics).not_to be_empty
            expect(err.diagnostics.first.code).to eq('VLT-IAM-WILDCARD-RESOURCE')
          }
      end
    end

    context 'unknown capability type' do
      it 'raises ValidationError for unsupported capability types' do
        cap = Veltrunode::Model::Capability.new(type: :unknown_capability, params: {})
        expect { expander.expand(cap) }
          .to raise_error(Veltrunode::ValidationError, /Unknown capability type/)
      end
    end
  end
end
