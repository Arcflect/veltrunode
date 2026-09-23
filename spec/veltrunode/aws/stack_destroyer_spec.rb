# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/aws/stack_destroyer'
require 'veltrunode/aws/change_set_manager' # StackEvent の定義を利用
require 'veltrunode/model/application'

RSpec.describe Veltrunode::AWS::StackDestroyer do
  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'my-app',
      region: 'ap-northeast-1',
      stage: 'dev'
    )
  end

  let(:mock_cfn_client) { instance_double('Aws::CloudFormation::Client') }

  subject(:destroyer) do
    described_class.new(
      application: application,
      cfn_client: mock_cfn_client,
      poll_interval: 0,
      max_polls: 5
    )
  end

  # スタックオブジェクトのダブルを生成するヘルパー
  def mock_stack(status)
    double('Stack', stack_status: status, stack_status_reason: nil)
  end

  # スタックイベントのダブルを生成するヘルパー
  def mock_cfn_event(event_id:, logical_id:, resource_type:, status:, reason: nil, timestamp: nil)
    double('CfnEvent',
           event_id: event_id,
           logical_resource_id: logical_id,
           physical_resource_id: nil,
           resource_type: resource_type,
           resource_status: status,
           resource_status_reason: reason,
           timestamp: timestamp || Time.now)
  end

  describe Veltrunode::AWS::StackResource do
    it 'holds resource attributes' do
      resource = described_class.new(
        logical_resource_id: 'MyBucket',
        physical_resource_id: 'my-actual-bucket',
        resource_type: 'AWS::S3::Bucket',
        resource_status: 'CREATE_COMPLETE'
      )

      expect(resource.logical_resource_id).to eq('MyBucket')
      expect(resource.physical_resource_id).to eq('my-actual-bucket')
      expect(resource.resource_type).to eq('AWS::S3::Bucket')
      expect(resource.resource_status).to eq('CREATE_COMPLETE')
    end

    it 'converts to hash' do
      resource = described_class.new(
        logical_resource_id: 'MyFunction',
        resource_type: 'AWS::Lambda::Function',
        resource_status: 'CREATE_COMPLETE'
      )

      expect(resource.to_h).to eq({
                                    'logical_resource_id' => 'MyFunction',
                                    'physical_resource_id' => nil,
                                    'resource_type' => 'AWS::Lambda::Function',
                                    'resource_status' => 'CREATE_COMPLETE'
                                  })
    end
  end

  describe '#stack_exists?' do
    it 'returns true when stack exists and is not DELETE_COMPLETE' do
      allow(mock_cfn_client).to receive(:describe_stacks)
        .with(stack_name: 'my-app-dev')
        .and_return(double('Resp', stacks: [mock_stack('CREATE_COMPLETE')]))

      expect(destroyer.stack_exists?('my-app-dev')).to be true
    end

    it 'returns false when stack status is DELETE_COMPLETE' do
      allow(mock_cfn_client).to receive(:describe_stacks)
        .with(stack_name: 'my-app-dev')
        .and_return(double('Resp', stacks: [mock_stack('DELETE_COMPLETE')]))

      expect(destroyer.stack_exists?('my-app-dev')).to be false
    end

    it 'returns false when stack does not exist' do
      allow(mock_cfn_client).to receive(:describe_stacks)
        .and_raise(RuntimeError.new('Stack with id my-app-dev does not exist'))

      expect(destroyer.stack_exists?('my-app-dev')).to be false
    end

    it 'raises StackDestroyError on unexpected AWS errors' do
      allow(mock_cfn_client).to receive(:describe_stacks)
        .and_raise(RuntimeError.new('Access Denied'))

      expect { destroyer.stack_exists?('my-app-dev') }
        .to raise_error(Veltrunode::AWS::StackDestroyError, /Access Denied/)
    end
  end

  describe '#describe_stack_resources' do
    it 'returns a list of StackResource objects' do
      raw_resource = double('CfnResource',
                            logical_resource_id: 'MyFunction',
                            physical_resource_id: 'arn:aws:lambda:ap-northeast-1:123:function:my-app-dev-MyFunction',
                            resource_type: 'AWS::Lambda::Function',
                            resource_status: 'CREATE_COMPLETE')

      allow(mock_cfn_client).to receive(:describe_stack_resources)
        .with(stack_name: 'my-app-dev')
        .and_return(double('Resp', stack_resources: [raw_resource]))

      resources = destroyer.describe_stack_resources('my-app-dev')

      expect(resources.size).to eq(1)
      expect(resources.first).to be_a(Veltrunode::AWS::StackResource)
      expect(resources.first.logical_resource_id).to eq('MyFunction')
      expect(resources.first.resource_type).to eq('AWS::Lambda::Function')
    end

    it 'returns empty array when no resources exist' do
      allow(mock_cfn_client).to receive(:describe_stack_resources)
        .and_return(double('Resp', stack_resources: []))

      expect(destroyer.describe_stack_resources('my-app-dev')).to eq([])
    end

    it 'raises StackDestroyError on error' do
      allow(mock_cfn_client).to receive(:describe_stack_resources)
        .and_raise(RuntimeError.new('Something went wrong'))

      expect { destroyer.describe_stack_resources('my-app-dev') }
        .to raise_error(Veltrunode::AWS::StackDestroyError, /Failed to describe resources/)
    end
  end

  describe '#delete_stack' do
    it 'calls CloudFormation delete_stack API' do
      expect(mock_cfn_client).to receive(:delete_stack).with(stack_name: 'my-app-dev')

      destroyer.delete_stack('my-app-dev')
    end

    it 'raises StackDestroyError on error' do
      allow(mock_cfn_client).to receive(:delete_stack)
        .and_raise(RuntimeError.new('Permission denied'))

      expect { destroyer.delete_stack('my-app-dev') }
        .to raise_error(Veltrunode::AWS::StackDestroyError, /Failed to delete stack/)
    end
  end

  describe '#wait_for_stack_deletion' do
    let(:stack_name) { 'my-app-dev' }

    let(:event1) do
      mock_cfn_event(
        event_id: 'ev-1',
        logical_id: 'MyFunction',
        resource_type: 'AWS::Lambda::Function',
        status: 'DELETE_IN_PROGRESS'
      )
    end

    let(:event2) do
      mock_cfn_event(
        event_id: 'ev-2',
        logical_id: 'my-app-dev',
        resource_type: 'AWS::CloudFormation::Stack',
        status: 'DELETE_COMPLETE'
      )
    end

    it 'yields events and returns when stack is deleted (not found)' do
      # 初期イベント取得（seen_event_ids に登録するため1件返す）
      # 続くポーリングでは新イベントを返す
      events_call_count = 0
      allow(mock_cfn_client).to receive(:describe_stack_events) do
        events_call_count += 1
        if events_call_count == 1
          # 初期取得: event1 のみ（見た済みに登録）
          double('Resp', stack_events: [event1])
        else
          # ポーリング時: event2（新規イベント）を返す
          double('Resp', stack_events: [event2, event1])
        end
      end

      # describe_stacks は1回目だけ DELETE_IN_PROGRESS、2回目以降はスタックなし
      stacks_call_count = 0
      allow(mock_cfn_client).to receive(:describe_stacks) do
        stacks_call_count += 1
        raise 'Stack with id my-app-dev does not exist' unless stacks_call_count == 1

        double('Resp', stacks: [mock_stack('DELETE_IN_PROGRESS')])
      end

      yielded_events = []
      events = destroyer.wait_for_stack_deletion(stack_name) { |ev| yielded_events << ev }

      expect(events).not_to be_empty
      expect(yielded_events.map(&:class)).to all(eq(Veltrunode::AWS::StackEvent))
    end

    it 'raises StackDestroyError when DELETE_FAILED is detected' do
      allow(mock_cfn_client).to receive(:describe_stack_events)
        .and_return(double('Resp', stack_events: []))

      allow(mock_cfn_client).to receive(:describe_stacks)
        .and_return(double('Resp', stacks: [mock_stack('DELETE_FAILED')]))

      expect { destroyer.wait_for_stack_deletion(stack_name) }
        .to raise_error(Veltrunode::AWS::StackDestroyError, /deletion failed with status 'DELETE_FAILED'/)
    end

    it 'raises StackDestroyError on timeout' do
      destroyer_short = described_class.new(
        application: application,
        cfn_client: mock_cfn_client,
        poll_interval: 0,
        max_polls: 2
      )

      allow(mock_cfn_client).to receive(:describe_stack_events)
        .and_return(double('Resp', stack_events: []))

      allow(mock_cfn_client).to receive(:describe_stacks)
        .and_return(double('Resp', stacks: [mock_stack('DELETE_IN_PROGRESS')]))

      expect { destroyer_short.wait_for_stack_deletion(stack_name) }
        .to raise_error(Veltrunode::AWS::StackDestroyError, /Timed out/)
    end

    it 'returns immediately when stack is already gone at start' do
      # 初期イベント取得でスタックが既にない
      allow(mock_cfn_client).to receive(:describe_stack_events)
        .and_raise(RuntimeError.new('Stack with id my-app-dev does not exist'))

      allow(mock_cfn_client).to receive(:describe_stacks)
        .and_raise(RuntimeError.new('Stack with id my-app-dev does not exist'))

      events = destroyer.wait_for_stack_deletion(stack_name)
      expect(events).to eq([])
    end
  end
end
