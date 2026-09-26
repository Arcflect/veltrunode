# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/deploy/pipeline'
require 'veltrunode/model/application'
require 'veltrunode/model/stage_policy'

RSpec.describe Veltrunode::Deploy::Pipeline do
  let(:app_dev) do
    Veltrunode::Model::Application.new(
      name: 'my-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      account_constraint: '123456789012'
    )
  end

  let(:app_prod) do
    Veltrunode::Model::Application.new(
      name: 'my-app',
      region: 'ap-northeast-1',
      stage: 'prod',
      account_constraint: '123456789012'
    )
  end

  let(:mock_build_result) do
    instance_double(
      'Veltrunode::Build::BuildResult',
      template_path: '/tmp/build/template.yml',
      manifest_path: '/tmp/build/manifest.json',
      function_results: [],
      layer_results: []
    )
  end

  let(:mock_change) do
    Veltrunode::AWS::ResourceChange.new(
      logical_resource_id: 'MyFunction',
      resource_type: 'AWS::Lambda::Function',
      action: 'Add'
    )
  end

  let(:mock_cs_result) do
    Veltrunode::AWS::ChangeSetResult.new(
      stack_name: 'my-app-dev',
      change_set_name: 'cs-123',
      changes: [mock_change]
    )
  end

  let(:mock_stack_event) do
    Veltrunode::AWS::StackEvent.new(
      event_id: 'ev-1',
      logical_resource_id: 'MyFunction',
      resource_type: 'AWS::Lambda::Function',
      resource_status: 'CREATE_COMPLETE',
      timestamp: Time.now
    )
  end

  let(:mock_cs_manager) { instance_double(Veltrunode::AWS::ChangeSetManager) }
  let(:mock_s3_uploader) { instance_double(Veltrunode::AWS::S3Uploader) }

  before do
    allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])
    allow(Veltrunode::Build::Pipeline).to receive(:execute).and_return(mock_build_result)
    allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
    allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_return(mock_cs_result)
    allow(mock_cs_manager).to receive(:execute_change_set)
    allow(mock_cs_manager).to receive(:wait_for_stack_completion)
      .and_yield(mock_stack_event).and_return([mock_stack_event])
  end

  describe 'Pipeline step execution' do
    it 'runs full pipeline successfully on dev stage' do
      yielded_events = []
      result = described_class.execute(
        app_dev,
        options: { change_set_manager: mock_cs_manager },
        on_progress: ->(ev) { yielded_events << ev }
      )

      expect(result.success?).to be true
      expect(result.exit_code).to eq(0)
      expect(result.stack_name).to eq('my-app-dev')
      expect(result.events.size).to eq(1)
      expect(yielded_events.size).to eq(1)
    end

    it 'aborts and returns exit code 3 on validation failure' do
      diag_err = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-DSL-001',
        severity: :error,
        summary: 'Invalid syntax',
        suggested_action: 'Fix syntax error'
      )
      allow(Veltrunode::Validation::Engine).to receive(:run).and_return([diag_err])

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(3)
      expect(result.message).to include('Validation failed with 1 error(s)')
    end

    it 'aborts and returns exit code 8 on stage policy violation' do
      policy_err = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-IAM-001',
        severity: :error,
        summary: 'Wildcard action denied',
        suggested_action: 'Remove wildcard action',
        evidence: { 'policy_violation' => true }
      )
      allow(Veltrunode::Validation::Engine).to receive(:run).and_return([policy_err])

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(8)
    end

    it 'aborts and returns exit code 5 on build failure' do
      allow(Veltrunode::Build::Pipeline).to receive(:execute).and_raise(RuntimeError.new('Docker error'))

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(5)
      expect(result.message).to include('Build failed: Docker error')
    end

    it 'aborts and returns exit code 4 on AWS account/region guard error' do
      guard_err = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-AWS-ACCOUNT-001',
        severity: :error,
        summary: 'Account mismatch',
        suggested_action: 'Switch AWS account'
      )
      allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([guard_err])

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(4)
      expect(result.message).to include('AWS verification failed with 1 error(s)')
    end

    it 'uploads artifacts to S3 if bucket is specified and fails with code 7 on upload error' do
      allow(mock_s3_uploader).to receive(:upload_and_update_template).and_raise(RuntimeError.new('S3 access denied'))

      result = described_class.execute(
        app_dev,
        options: {
          bucket: 'my-artifacts-bucket',
          s3_uploader: mock_s3_uploader,
          change_set_manager: mock_cs_manager
        }
      )

      expect(result.success?).to be false
      expect(result.exit_code).to eq(7)
      expect(result.message).to include('S3 upload failed: S3 access denied')
    end

    it 'returns exit code 0 without executing change set when no changes are detected' do
      empty_cs = Veltrunode::AWS::ChangeSetResult.new(
        stack_name: 'my-app-dev',
        change_set_name: 'cs-empty',
        changes: []
      )
      allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_return(empty_cs)
      expect(mock_cs_manager).not_to receive(:execute_change_set)

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be true
      expect(result.exit_code).to eq(0)
      expect(result.no_changes?).to be true
      expect(result.message).to include('No changes detected')
    end

    context 'with protected stage' do
      it 'prompts for approval and proceeds when user approves' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('prod', kind_of(Veltrunode::AWS::ChangeSetResult)).and_return(true)

        result = described_class.execute(
          app_prod,
          options: { change_set_manager: mock_cs_manager },
          prompter: prompter
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
      end

      it 'prompts for approval and aborts with code 7 when user cancels' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('prod', kind_of(Veltrunode::AWS::ChangeSetResult)).and_return(false)

        result = described_class.execute(
          app_prod,
          options: { change_set_manager: mock_cs_manager },
          prompter: prompter
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(7)
        expect(result.message).to include('cancelled by user')
      end

      it 'skips approval prompt when --yes is provided' do
        prompter = instance_double(Proc)
        expect(prompter).not_to receive(:call)

        result = described_class.execute(
          app_prod,
          options: { yes: true, change_set_manager: mock_cs_manager },
          prompter: prompter
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
      end
    end

    it 'aborts and returns exit code 7 on Change Set execution error' do
      allow(mock_cs_manager).to receive(:execute_change_set).and_raise(
        Veltrunode::AWS::ChangeSetError.new('Execution failed')
      )

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(7)
      expect(result.message).to include('Failed to execute Change Set')
    end

    it 'aborts and returns exit code 7 on stack update failure' do
      allow(mock_cs_manager).to receive(:wait_for_stack_completion).and_raise(
        Veltrunode::AWS::ChangeSetError.new("deployment failed with status 'ROLLBACK_COMPLETE'")
      )

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(7)
      expect(result.message).to include('Stack update failed')
    end

    it 'diagnoses rollback cause and attaches diagnostics on stack update failure' do
      failed_event = Veltrunode::AWS::StackEvent.new(
        event_id: 'ev-err',
        logical_resource_id: 'WorkerFunction',
        resource_type: 'AWS::Lambda::Function',
        resource_status: 'CREATE_FAILED',
        resource_status_reason: 'User is not authorized to perform: lambda:CreateFunction'
      )
      allow(mock_cs_manager).to receive(:wait_for_stack_completion).and_raise(
        Veltrunode::AWS::ChangeSetError.new(
          "deployment failed with status 'ROLLBACK_COMPLETE'",
          events: [failed_event]
        )
      )

      result = described_class.execute(app_dev, options: { change_set_manager: mock_cs_manager })

      expect(result.success?).to be false
      expect(result.exit_code).to eq(7)
      expect(result.message).to include('Stack update failed')
      expect(result.diagnostics).not_to be_empty
      diag = result.diagnostics.find { |d| d.code == 'VLT-CFN-ROLLBACK-IAM' }
      expect(diag).not_to be_nil
      expect(diag.summary).to include("Resource 'WorkerFunction' (AWS::Lambda::Function) failed")
      expect(diag.suggested_action).to include("for 'lambda:CreateFunction'")
    end
  end
end
