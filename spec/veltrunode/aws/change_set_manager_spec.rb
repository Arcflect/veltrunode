# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/aws/change_set_manager'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::AWS::ChangeSetManager do
  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'plan-app',
      region: 'ap-northeast-1',
      stage: 'dev'
    )
  end

  let(:mock_cfn_client) { instance_double('Aws::CloudFormation::Client') }

  subject(:manager) do
    described_class.new(
      application: application,
      cfn_client: mock_cfn_client,
      poll_interval: 0,
      max_polls: 5
    )
  end

  describe Veltrunode::AWS::ResourceChange do
    it 'determines display action correctly' do
      rc_add = described_class.new(logical_resource_id: 'Fn1', resource_type: 'AWS::Lambda::Function', action: 'Add')
      expect(rc_add.display_action).to eq(:add)
      expect(rc_add.add?).to be true

      rc_mod = described_class.new(logical_resource_id: 'Fn1', resource_type: 'AWS::Lambda::Function',
                                   action: 'Modify', replacement: 'Never')
      expect(rc_mod.display_action).to eq(:modify)
      expect(rc_mod.modify?).to be true

      rc_rep = described_class.new(logical_resource_id: 'Role1', resource_type: 'AWS::IAM::Role', action: 'Modify',
                                   replacement: 'Always')
      expect(rc_rep.display_action).to eq(:replace)
      expect(rc_rep.replace?).to be true
      expect(rc_rep.action).to eq('Replace')

      rc_rem = described_class.new(logical_resource_id: 'OldQueue', resource_type: 'AWS::SQS::Queue', action: 'Remove')
      expect(rc_rem.display_action).to eq(:remove)
      expect(rc_rem.remove?).to be true
    end

    it 'converts to hash' do
      rc = described_class.new(
        logical_resource_id: 'Fn1',
        physical_resource_id: 'arn:aws:lambda:...',
        resource_type: 'AWS::Lambda::Function',
        action: 'Modify',
        replacement: 'Never'
      )

      expect(rc.to_h).to eq({
                              'logical_resource_id' => 'Fn1',
                              'physical_resource_id' => 'arn:aws:lambda:...',
                              'resource_type' => 'AWS::Lambda::Function',
                              'action' => 'Modify',
                              'replacement' => 'Never',
                              'display_action' => 'modify'
                            })
    end
  end

  describe Veltrunode::AWS::ChangeSetResult do
    it 'calculates summary correctly' do
      c1 = Veltrunode::AWS::ResourceChange.new(logical_resource_id: 'Fn1', resource_type: 'AWS::Lambda::Function',
                                               action: 'Add')
      c2 = Veltrunode::AWS::ResourceChange.new(logical_resource_id: 'Fn2', resource_type: 'AWS::Lambda::Function',
                                               action: 'Modify', replacement: 'Never')
      c3 = Veltrunode::AWS::ResourceChange.new(logical_resource_id: 'Role1', resource_type: 'AWS::IAM::Role',
                                               action: 'Modify', replacement: 'Always')
      c4 = Veltrunode::AWS::ResourceChange.new(logical_resource_id: 'OldFn', resource_type: 'AWS::Lambda::Function',
                                               action: 'Remove')

      result = described_class.new(
        stack_name: 'plan-app-dev',
        change_set_name: 'cs-123',
        changes: [c1, c2, c3, c4]
      )

      expect(result.summary).to eq({ add: 1, modify: 1, replace: 1, remove: 1 })
      expect(result.empty?).to be false
      expect(result.to_h['summary']).to eq({ 'add' => 1, 'modify' => 1, 'replace' => 1, 'remove' => 1 })
    end
  end

  describe '#create_and_describe_change_set' do
    let(:template_yaml) do
      <<~YAML
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          MyFunction:
            Type: AWS::Lambda::Function
      YAML
    end

    context 'when creating a new stack Change Set (stack does not exist)' do
      before do
        not_found_err = StandardError.new('Stack with id plan-app-dev does not exist')
        allow(mock_cfn_client).to receive(:describe_stacks).and_raise(not_found_err)
        allow(mock_cfn_client).to receive(:create_change_set)

        describe_resp = double(
          'DescribeChangeSetResponse',
          status: 'CREATE_COMPLETE',
          changes: [
            double(
              'Change',
              type: 'Resource',
              resource_change: double(
                'ResourceChange',
                logical_resource_id: 'MyFunction',
                physical_resource_id: nil,
                resource_type: 'AWS::Lambda::Function',
                action: 'Add',
                replacement: 'Never'
              )
            )
          ]
        )
        allow(mock_cfn_client).to receive(:describe_change_set).and_return(describe_resp)
      end

      it 'calls create_change_set with change_set_type CREATE and parses changes' do
        result = manager.create_and_describe_change_set(template_yaml)

        expect(mock_cfn_client).to have_received(:create_change_set).with(
          stack_name: 'plan-app-dev',
          change_set_name: start_with('veltrunode-plan-'),
          template_body: template_yaml,
          capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND],
          change_set_type: 'CREATE'
        )

        expect(result.stack_name).to eq('plan-app-dev')
        expect(result.summary[:add]).to eq(1)
        expect(result.changes.first.logical_resource_id).to eq('MyFunction')
      end
    end

    context 'when updating an existing stack Change Set (stack exists)' do
      before do
        stacks_resp = double('DescribeStacksResponse', stacks: [double('Stack', stack_status: 'CREATE_COMPLETE')])
        allow(mock_cfn_client).to receive(:describe_stacks).and_return(stacks_resp)
        allow(mock_cfn_client).to receive(:create_change_set)

        describe_resp = double(
          'DescribeChangeSetResponse',
          status: 'CREATE_COMPLETE',
          changes: [
            double(
              'Change',
              type: 'Resource',
              resource_change: double(
                'ResourceChange',
                logical_resource_id: 'MyFunction',
                physical_resource_id: 'arn:aws:lambda:...',
                resource_type: 'AWS::Lambda::Function',
                action: 'Modify',
                replacement: 'Never'
              )
            ),
            double(
              'Change',
              type: 'Resource',
              resource_change: double(
                'ResourceChange',
                logical_resource_id: 'MyRole',
                physical_resource_id: 'arn:aws:iam:...',
                resource_type: 'AWS::IAM::Role',
                action: 'Modify',
                replacement: 'Always'
              )
            )
          ]
        )
        allow(mock_cfn_client).to receive(:describe_change_set).and_return(describe_resp)
      end

      it 'calls create_change_set with change_set_type UPDATE and classifies Modify / Replace' do
        result = manager.create_and_describe_change_set(template_yaml)

        expect(mock_cfn_client).to have_received(:create_change_set).with(
          stack_name: 'plan-app-dev',
          change_set_name: start_with('veltrunode-plan-'),
          template_body: template_yaml,
          capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND],
          change_set_type: 'UPDATE'
        )

        expect(result.summary[:modify]).to eq(1)
        expect(result.summary[:replace]).to eq(1)
        expect(result.changes.map(&:action)).to contain_exactly('Modify', 'Replace')
      end
    end

    context 'when Change Set results in FAILED with "No changes"' do
      before do
        stacks_resp = double('DescribeStacksResponse', stacks: [double('Stack', stack_status: 'CREATE_COMPLETE')])
        allow(mock_cfn_client).to receive(:describe_stacks).and_return(stacks_resp)
        allow(mock_cfn_client).to receive(:create_change_set)

        failed_resp = double(
          'DescribeChangeSetResponse',
          status: 'FAILED',
          status_reason: 'The submitted information causes no changes to the set.'
        )
        allow(mock_cfn_client).to receive(:describe_change_set).and_return(failed_resp)
      end

      it 'returns a successful empty ChangeSetResult with 0 changes' do
        result = manager.create_and_describe_change_set(template_yaml)

        expect(result.empty?).to be true
        expect(result.summary).to eq({ add: 0, modify: 0, replace: 0, remove: 0 })
      end
    end

    context 'when Change Set results in FAILED with actual error' do
      before do
        stacks_resp = double('DescribeStacksResponse', stacks: [double('Stack', stack_status: 'CREATE_COMPLETE')])
        allow(mock_cfn_client).to receive(:describe_stacks).and_return(stacks_resp)
        allow(mock_cfn_client).to receive(:create_change_set)

        failed_resp = double(
          'DescribeChangeSetResponse',
          status: 'FAILED',
          status_reason: 'Template format error: Unresolved resource dependency'
        )
        allow(mock_cfn_client).to receive(:describe_change_set).and_return(failed_resp)
      end

      it 'raises ChangeSetError with the status reason' do
        expect do
          manager.create_and_describe_change_set(template_yaml)
        end.to raise_error(Veltrunode::AWS::ChangeSetError, /Template format error/)
      end
    end

    context 'when Change Set polling times out' do
      before do
        stacks_resp = double('DescribeStacksResponse', stacks: [double('Stack', stack_status: 'CREATE_COMPLETE')])
        allow(mock_cfn_client).to receive(:describe_stacks).and_return(stacks_resp)
        allow(mock_cfn_client).to receive(:create_change_set)

        pending_resp = double('DescribeChangeSetResponse', status: 'CREATE_IN_PROGRESS')
        allow(mock_cfn_client).to receive(:describe_change_set).and_return(pending_resp)
      end

      it 'raises ChangeSetError on timeout' do
        expect do
          manager.create_and_describe_change_set(template_yaml)
        end.to raise_error(Veltrunode::AWS::ChangeSetError, /Timed out waiting for Change Set/)
      end
    end
  end

  describe '#execute_change_set' do
    it 'executes the change set via cloudformation client' do
      expect(mock_cfn_client).to receive(:execute_change_set).with(
        stack_name: 'plan-app-dev',
        change_set_name: 'cs-123'
      )

      manager.execute_change_set(stack_name: 'plan-app-dev', change_set_name: 'cs-123')
    end

    it 'wraps StandardError into ChangeSetError' do
      allow(mock_cfn_client).to receive(:execute_change_set).and_raise(RuntimeError.new('Execution denied'))

      msg = "Failed to execute Change Set 'cs-123' for stack 'plan-app-dev': Execution denied"
      expect do
        manager.execute_change_set(stack_name: 'plan-app-dev', change_set_name: 'cs-123')
      end.to raise_error(Veltrunode::AWS::ChangeSetError, Regexp.new(Regexp.escape(msg)))
    end
  end

  describe '#wait_for_stack_completion' do
    let(:event1) do
      double(
        'StackEvent',
        event_id: 'ev-1',
        logical_resource_id: 'MyFunction',
        physical_resource_id: 'arn:aws:lambda:...',
        resource_type: 'AWS::Lambda::Function',
        resource_status: 'CREATE_IN_PROGRESS',
        resource_status_reason: nil,
        timestamp: Time.now
      )
    end

    let(:event2) do
      double(
        'StackEvent',
        event_id: 'ev-2',
        logical_resource_id: 'MyFunction',
        physical_resource_id: 'arn:aws:lambda:...',
        resource_type: 'AWS::Lambda::Function',
        resource_status: 'CREATE_COMPLETE',
        resource_status_reason: nil,
        timestamp: Time.now
      )
    end

    it 'polls events and completes when stack status is UPDATE_COMPLETE' do
      # 初期イベント
      allow(mock_cfn_client).to receive(:describe_stack_events).with(stack_name: 'plan-app-dev')
                                                               .and_return(
                                                                 double('EventsResp', stack_events: []),
                                                                 double('EventsResp', stack_events: [event2, event1])
                                                               )

      stack_obj = double('Stack', stack_status: 'UPDATE_COMPLETE')
      allow(mock_cfn_client).to receive(:describe_stacks).with(stack_name: 'plan-app-dev')
                                                         .and_return(double('StacksResp', stacks: [stack_obj]))

      yielded_events = []
      events = manager.wait_for_stack_completion('plan-app-dev') do |ev|
        yielded_events << ev
      end

      expect(events.size).to eq(2)
      expect(yielded_events.map(&:logical_resource_id)).to eq(%w[MyFunction MyFunction])
      expect(events.first.resource_status).to eq('CREATE_IN_PROGRESS')
      expect(events.last.resource_status).to eq('CREATE_COMPLETE')
    end

    it 'raises ChangeSetError when stack deployment fails' do
      allow(mock_cfn_client).to receive(:describe_stack_events).and_return(double('EventsResp', stack_events: []))
      failed_stack = double('Stack', stack_status: 'UPDATE_ROLLBACK_COMPLETE',
                                     stack_status_reason: 'Resource creation cancelled')
      allow(mock_cfn_client).to receive(:describe_stacks).and_return(double('StacksResp', stacks: [failed_stack]))

      expect do
        manager.wait_for_stack_completion('plan-app-dev')
      end.to raise_error(Veltrunode::AWS::ChangeSetError, /deployment failed with status 'UPDATE_ROLLBACK_COMPLETE'/)
    end

    it 'attaches collected events to ChangeSetError when deployment fails' do
      failed_event = double('StackEvent',
                            event_id: 'ev-fail-1',
                            logical_resource_id: 'MyFunction',
                            physical_resource_id: 'arn:aws:lambda:...',
                            resource_type: 'AWS::Lambda::Function',
                            resource_status: 'CREATE_FAILED',
                            resource_status_reason: 'User is not authorized to perform: lambda:CreateFunction',
                            timestamp: Time.now)
      allow(mock_cfn_client).to receive(:describe_stack_events).and_return(
        double('EventsResp', stack_events: []),
        double('EventsResp', stack_events: [failed_event])
      )
      failed_stack = double('Stack', stack_status: 'ROLLBACK_COMPLETE',
                                     stack_status_reason: 'The following resource(s) failed to create: [MyFunction].')
      allow(mock_cfn_client).to receive(:describe_stacks).and_return(double('StacksResp', stacks: [failed_stack]))

      begin
        manager.wait_for_stack_completion('plan-app-dev')
        raise 'Expected ChangeSetError'
      rescue Veltrunode::AWS::ChangeSetError => e
        expect(e.events).not_to be_empty
        expect(e.events.first.logical_resource_id).to eq('MyFunction')
        expect(e.events.first.resource_status).to eq('CREATE_FAILED')
      end
    end

    it 'raises ChangeSetError on timeout' do
      allow(mock_cfn_client).to receive(:describe_stack_events).and_return(double('EventsResp', stack_events: []))
      in_progress_stack = double('Stack', stack_status: 'UPDATE_IN_PROGRESS')
      allow(mock_cfn_client).to receive(:describe_stacks).and_return(double('StacksResp', stacks: [in_progress_stack]))

      expect do
        manager.wait_for_stack_completion('plan-app-dev')
      end.to raise_error(Veltrunode::AWS::ChangeSetError, /Timed out waiting for stack 'plan-app-dev' completion/)
    end

    describe '#fetch_all_stack_events' do
      it 'fetches and converts all stack events' do
        raw_event = double('StackEvent',
                           event_id: 'ev-all-1',
                           logical_resource_id: 'MyFunction',
                           physical_resource_id: 'arn:aws:lambda:...',
                           resource_type: 'AWS::Lambda::Function',
                           resource_status: 'CREATE_FAILED',
                           resource_status_reason: 'AccessDenied',
                           timestamp: Time.now)
        allow(mock_cfn_client).to receive(:describe_stack_events).with(stack_name: 'plan-app-dev').and_return(
          double('EventsResp', stack_events: [raw_event])
        )

        events = manager.fetch_all_stack_events('plan-app-dev')
        expect(events.size).to eq(1)
        expect(events.first.logical_resource_id).to eq('MyFunction')
      end
    end
  end
end
