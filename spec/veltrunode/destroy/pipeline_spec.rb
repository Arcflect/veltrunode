# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/destroy/pipeline'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::Destroy::Pipeline do
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

  let(:mock_resource) do
    Veltrunode::AWS::StackResource.new(
      logical_resource_id: 'MyFunction',
      physical_resource_id: 'arn:aws:lambda:...',
      resource_type: 'AWS::Lambda::Function',
      resource_status: 'CREATE_COMPLETE'
    )
  end

  let(:mock_event) do
    Veltrunode::AWS::StackEvent.new(
      event_id: 'ev-1',
      logical_resource_id: 'my-app-dev',
      resource_type: 'AWS::CloudFormation::Stack',
      resource_status: 'DELETE_COMPLETE',
      timestamp: Time.now
    )
  end

  let(:mock_destroyer) { instance_double(Veltrunode::AWS::StackDestroyer) }

  before do
    allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
    allow(mock_destroyer).to receive(:stack_exists?).and_return(true)
    allow(mock_destroyer).to receive(:describe_stack_resources).and_return([mock_resource])
    allow(mock_destroyer).to receive(:delete_stack)
    allow(mock_destroyer).to receive(:wait_for_stack_deletion)
      .and_yield(mock_event).and_return([mock_event])
  end

  describe 'Pipeline step execution' do
    context '非保護ステージ（dev）' do
      it '--yes オプション指定時は確認なしでスタックを削除する' do
        result = described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer }
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
        expect(result.stack_name).to eq('my-app-dev')
        expect(result.resources.size).to eq(1)
        expect(result.events.size).to eq(1)
        expect(result.message).to include('successfully deleted')
      end

      it 'プロンプターが承認を返したとき削除が成功する' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('dev', 'my-app-dev').and_return(true)

        result = described_class.execute(
          app_dev,
          options: { stack_destroyer: mock_destroyer },
          prompter: prompter
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
      end

      it 'プロンプターがキャンセルを返したとき exit_code 7 で終了する' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('dev', 'my-app-dev').and_return(false)

        result = described_class.execute(
          app_dev,
          options: { stack_destroyer: mock_destroyer },
          prompter: prompter
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(7)
        expect(result.message).to include('cancelled by user')
      end
    end

    context '保護ステージ（prod）' do
      it 'プロンプターが承認（スタック名一致）を返したとき削除が成功する' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('prod', 'my-app-prod').and_return(true)

        # prod 用に mock_destroyer のスタック名期待値を調整
        allow(mock_destroyer).to receive(:stack_exists?).with('my-app-prod').and_return(true)
        allow(mock_destroyer).to receive(:describe_stack_resources).with('my-app-prod').and_return([mock_resource])
        allow(mock_destroyer).to receive(:delete_stack).with('my-app-prod')
        allow(mock_destroyer).to receive(:wait_for_stack_deletion).with('my-app-prod')
                                                                  .and_yield(mock_event).and_return([mock_event])

        result = described_class.execute(
          app_prod,
          options: { stack_destroyer: mock_destroyer },
          prompter: prompter
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
      end

      it 'プロンプターがキャンセル（スタック名不一致）を返したとき exit_code 7 で終了する' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('prod', 'my-app-prod').and_return(false)

        allow(mock_destroyer).to receive(:stack_exists?).with('my-app-prod').and_return(true)
        allow(mock_destroyer).to receive(:describe_stack_resources).with('my-app-prod').and_return([mock_resource])

        result = described_class.execute(
          app_prod,
          options: { stack_destroyer: mock_destroyer },
          prompter: prompter
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(7)
        expect(result.message).to include('cancelled by user')
      end

      it '--yes オプションがあっても保護ステージではプロンプターを呼び出す' do
        prompter = instance_double(Proc)
        expect(prompter).to receive(:call).with('prod', 'my-app-prod').and_return(true)

        allow(mock_destroyer).to receive(:stack_exists?).with('my-app-prod').and_return(true)
        allow(mock_destroyer).to receive(:describe_stack_resources).with('my-app-prod').and_return([mock_resource])
        allow(mock_destroyer).to receive(:delete_stack).with('my-app-prod')
        allow(mock_destroyer).to receive(:wait_for_stack_deletion).with('my-app-prod')
                                                                  .and_return([mock_event])

        # 保護ステージでは --yes があっても prompter が呼ばれることを確認
        result = described_class.execute(
          app_prod,
          options: { yes: true, stack_destroyer: mock_destroyer },
          prompter: prompter
        )

        expect(result.success?).to be true
      end
    end

    context 'スタックが存在しない場合' do
      it 'スタック不在を報告して exit_code 0 で正常終了する' do
        allow(mock_destroyer).to receive(:stack_exists?).and_return(false)

        result = described_class.execute(
          app_dev,
          options: { stack_destroyer: mock_destroyer }
        )

        expect(result.success?).to be true
        expect(result.exit_code).to eq(0)
        expect(result.stack_not_found?).to be true
        expect(result.message).to include('does not exist')
        expect(mock_destroyer).not_to have_received(:delete_stack)
      end
    end

    context 'AWS Guard 失敗' do
      it 'AWS Guard エラー時に exit_code 4 で終了する' do
        diag_err = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-001',
          severity: :error,
          summary: 'Account mismatch',
          suggested_action: 'Check AWS credentials'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([diag_err])

        result = described_class.execute(
          app_dev,
          options: { stack_destroyer: mock_destroyer }
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(4)
        expect(result.message).to include('AWS verification failed')
      end
    end

    context 'on_preview コールバック' do
      it 'リソース一覧を on_preview に渡す' do
        previewed_stack_name = nil
        previewed_resources = nil

        described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer },
          on_preview: lambda { |sn, resources|
            previewed_stack_name = sn
            previewed_resources = resources
          }
        )

        expect(previewed_stack_name).to eq('my-app-dev')
        expect(previewed_resources).to eq([mock_resource])
      end
    end

    context 'on_progress コールバック' do
      it '削除中のスタックイベントを on_progress に渡す' do
        yielded_events = []

        described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer },
          on_progress: ->(ev) { yielded_events << ev }
        )

        expect(yielded_events.size).to eq(1)
        expect(yielded_events.first).to be_a(Veltrunode::AWS::StackEvent)
      end
    end

    context '削除失敗' do
      it 'delete_stack でエラー発生時に exit_code 7 で終了する' do
        allow(mock_destroyer).to receive(:delete_stack)
          .and_raise(RuntimeError.new('Termination protection enabled'))

        result = described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer }
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(7)
        expect(result.message).to include('Failed to delete stack')
      end

      it 'wait_for_stack_deletion でエラー発生時に exit_code 7 で終了する' do
        allow(mock_destroyer).to receive(:wait_for_stack_deletion)
          .and_raise(Veltrunode::AWS::StackDestroyError.new("deletion failed with status 'DELETE_FAILED'"))

        result = described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer }
        )

        expect(result.success?).to be false
        expect(result.exit_code).to eq(7)
        expect(result.message).to include('Stack deletion failed')
      end
    end

    context 'DestroyResult' do
      it 'to_h で正しいハッシュ表現を返す' do
        result = described_class.execute(
          app_dev,
          options: { yes: true, stack_destroyer: mock_destroyer }
        )

        h = result.to_h
        expect(h['status']).to eq('success')
        expect(h['stack_name']).to eq('my-app-dev')
        expect(h['resources']).to be_an(Array)
        expect(h['events']).to be_an(Array)
      end
    end
  end

  describe '#protected_stage?' do
    it 'dev は保護ステージでない' do
      pipeline = described_class.new(app_dev)
      expect(pipeline.protected_stage?).to be false
    end

    it 'prod は保護ステージ' do
      pipeline = described_class.new(app_prod)
      expect(pipeline.protected_stage?).to be true
    end

    it 'staging は保護ステージ' do
      app_staging = Veltrunode::Model::Application.new(name: 'my-app', stage: 'staging')
      pipeline = described_class.new(app_staging)
      expect(pipeline.protected_stage?).to be true
    end

    it 'production は保護ステージ' do
      app_production = Veltrunode::Model::Application.new(name: 'my-app', stage: 'production')
      pipeline = described_class.new(app_production)
      expect(pipeline.protected_stage?).to be true
    end
  end
end
