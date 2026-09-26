# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/aws/rollback_diagnoser'
require 'veltrunode/aws/change_set_manager'

RSpec.describe Veltrunode::AWS::RollbackDiagnoser do
  let(:stack_name) { 'my-app-dev' }

  def create_event(
    logical_resource_id:,
    resource_type:,
    resource_status:,
    resource_status_reason: nil,
    physical_resource_id: nil,
    timestamp: Time.now
  )
    Veltrunode::AWS::StackEvent.new(
      event_id: "ev-#{SecureRandom.hex(4)}",
      logical_resource_id: logical_resource_id,
      physical_resource_id: physical_resource_id,
      resource_type: resource_type,
      resource_status: resource_status,
      resource_status_reason: resource_status_reason,
      timestamp: timestamp
    )
  end

  describe '#diagnose' do
    context 'when failure is caused by IAM permission denial' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'WorkerFunction',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_IN_PROGRESS',
            timestamp: Time.now - 10
          ),
          create_event(
            logical_resource_id: 'WorkerFunction',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'User: arn:aws:iam::123456789012:user/deployer is not authorized to perform: ' \
                                    'lambda:CreateFunction on resource: *',
            timestamp: Time.now - 8
          ),
          create_event(
            logical_resource_id: 'OtherResource',
            resource_type: 'AWS::Logs::LogGroup',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'Resource creation cancelled',
            timestamp: Time.now - 7
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_IN_PROGRESS',
            resource_status_reason: 'The following resource(s) failed to create: [WorkerFunction]. ' \
                                    'Rollback requested by user.',
            timestamp: Time.now - 6
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_COMPLETE',
            timestamp: Time.now
          )
        ]
      end

      it 'diagnoses the IAM error and generates VLT-CFN-ROLLBACK-IAM diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK-IAM')
        expect(diag.severity).to eq(:error)
        expect(diag.summary).to include("Resource 'WorkerFunction' (AWS::Lambda::Function) failed")
        expect(diag.summary).to include('is not authorized to perform: lambda:CreateFunction')
        expect(diag.suggested_action).to include("for 'lambda:CreateFunction'")
        expect(diag.aws_resource_id).to eq('WorkerFunction')
        expect(diag.evidence['category']).to eq('iam_permission_denied')
        expect(diag.evidence['logical_resource_id']).to eq('WorkerFunction')
        expect(diag.evidence['resource_status']).to eq('CREATE_FAILED')
      end
    end

    context 'when failure is caused by resource limit or quota exceeded' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'WorkerFunction',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'UPDATE_FAILED',
            resource_status_reason: 'The ResourceLimitExceeded: Function count limit exceeded for this account.',
            timestamp: Time.now - 5
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'UPDATE_ROLLBACK_COMPLETE',
            timestamp: Time.now
          )
        ]
      end

      it 'diagnoses the limit error and generates VLT-CFN-ROLLBACK-LIMIT diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK-LIMIT')
        expect(diag.severity).to eq(:error)
        expect(diag.suggested_action).to include('Service Quotas')
        expect(diag.evidence['category']).to eq('resource_limit_exceeded')
      end
    end

    context 'when failure is caused by resource conflict / already exists' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'ConfigBucket',
            resource_type: 'AWS::S3::Bucket',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'Bucket already exists in region ap-northeast-1.',
            timestamp: Time.now - 5
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_COMPLETE',
            timestamp: Time.now
          )
        ]
      end

      it 'diagnoses resource conflict and generates VLT-CFN-ROLLBACK-EXISTS diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK-EXISTS')
        expect(diag.severity).to eq(:error)
        expect(diag.suggested_action).to include('already exists')
        expect(diag.evidence['category']).to eq('resource_conflict')
      end
    end

    context 'when failure is caused by invalid configuration / parameters' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'WorkerFunction',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'InvalidParameterValue: Memory size must be a multiple of 64 MB.',
            timestamp: Time.now - 5
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_COMPLETE',
            timestamp: Time.now
          )
        ]
      end

      it 'diagnoses invalid config and generates VLT-CFN-ROLLBACK-CONFIG diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK-CONFIG')
        expect(diag.severity).to eq(:error)
        expect(diag.suggested_action).to include('Review the resource configuration')
        expect(diag.evidence['category']).to eq('invalid_configuration')
      end
    end

    context 'when failure is caused by an unclassified error' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'CustomResource',
            resource_type: 'Custom::SetupRunner',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'Service responded with internal 500 error during setup hook.',
            timestamp: Time.now - 5
          ),
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_COMPLETE',
            timestamp: Time.now
          )
        ]
      end

      it 'generates general VLT-CFN-ROLLBACK diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK')
        expect(diag.severity).to eq(:error)
        expect(diag.suggested_action).to include('Inspect the CloudFormation event details')
        expect(diag.evidence['category']).to eq('general_failure')
      end
    end

    context 'when multiple resources fail simultaneously' do
      let(:events) do
        [
          create_event(
            logical_resource_id: 'FunctionA',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'User is not authorized to perform: lambda:CreateFunction',
            timestamp: Time.now - 10
          ),
          create_event(
            logical_resource_id: 'FunctionB',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'ResourceLimitExceeded: Function limit reached',
            timestamp: Time.now - 8
          ),
          create_event(
            logical_resource_id: 'FunctionC',
            resource_type: 'AWS::Lambda::Function',
            resource_status: 'CREATE_FAILED',
            resource_status_reason: 'Resource creation cancelled',
            timestamp: Time.now - 6
          )
        ]
      end

      it 'diagnoses each root cause failure and excludes cancelled ones' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(2)
        codes = diagnostics.map(&:code)
        expect(codes).to contain_exactly('VLT-CFN-ROLLBACK-IAM', 'VLT-CFN-ROLLBACK-LIMIT')
      end
    end

    context 'when only stack-level failure event is present' do
      let(:events) do
        [
          create_event(
            logical_resource_id: stack_name,
            resource_type: 'AWS::CloudFormation::Stack',
            resource_status: 'ROLLBACK_FAILED',
            resource_status_reason: 'Export "MyVpcSubnet" cannot be deleted as it is in use by another stack.',
            timestamp: Time.now
          )
        ]
      end

      it 'uses stack-level failure to generate diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: events)

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first

        expect(diag.code).to eq('VLT-CFN-ROLLBACK')
        expect(diag.aws_resource_id).to eq(stack_name)
        expect(diag.summary).to include("Resource '#{stack_name}' (AWS::CloudFormation::Stack) failed")
      end
    end

    context 'when events array is empty but client is provided' do
      let(:mock_client) { double('Aws::CloudFormation::Client') }
      let(:raw_event) do
        double(
          'StackEvent',
          event_id: 'ev-client-1',
          logical_resource_id: 'WorkerFunction',
          physical_resource_id: 'arn:aws:lambda:...',
          resource_type: 'AWS::Lambda::Function',
          resource_status: 'CREATE_FAILED',
          resource_status_reason: 'AccessDenied: user is not authorized to perform: lambda:CreateFunction',
          timestamp: Time.now
        )
      end

      before do
        allow(mock_client).to receive(:describe_stack_events).with(stack_name: stack_name).and_return(
          double('EventsResponse', stack_events: [raw_event])
        )
      end

      it 'fetches events from client and diagnoses the error' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: [], client: mock_client)

        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.code).to eq('VLT-CFN-ROLLBACK-IAM')
        expect(diagnostics.first.aws_resource_id).to eq('arn:aws:lambda:...')
      end
    end

    context 'when no events and no client' do
      it 'returns a fallback diagnostic' do
        diagnostics = described_class.diagnose(stack_name: stack_name, events: [])

        expect(diagnostics.size).to eq(1)
        diag = diagnostics.first
        expect(diag.code).to eq('VLT-CFN-ROLLBACK')
        expect(diag.summary).to include("Stack '#{stack_name}' update failed and rolled back.")
      end
    end
  end
end
