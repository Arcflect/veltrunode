# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'veltrunode/aws/layer_cleaner'
require 'veltrunode/model/application'
require 'veltrunode/model/layer'
require 'veltrunode/model/function'

RSpec.describe Veltrunode::AWS::LayerCleaner do
  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'shared_libs',
      compatible_runtimes: ['ruby3.3'],
      retention_policy: { latest: 3 }
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'cleaner-test-app',
      stage: 'dev',
      region: 'ap-northeast-1',
      layers: [layer]
    )
  end

  let(:mock_versions) do
    [
      {
        'version' => 6,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:6',
        'created_date' => '2026-10-06T10:00:00Z',
        'description' => 'v6'
      },
      {
        'version' => 5,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:5',
        'created_date' => '2026-10-05T10:00:00Z',
        'description' => 'v5'
      },
      {
        'version' => 4,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:4',
        'created_date' => '2026-10-04T10:00:00Z',
        'description' => 'v4'
      },
      {
        'version' => 3,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:3',
        'created_date' => '2026-10-03T10:00:00Z',
        'description' => 'v3'
      },
      {
        'version' => 2,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:2',
        'created_date' => '2026-10-02T10:00:00Z',
        'description' => 'v2'
      },
      {
        'version' => 1,
        'layer_version_arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:1',
        'created_date' => '2026-10-01T10:00:00Z',
        'description' => 'v1'
      }
    ]
  end

  let(:mock_functions) do
    [
      {
        'function_name' => 'api_handler',
        'layers' => [
          { 'arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:3' }
        ]
      },
      {
        'function_name' => 'worker_job',
        'layers' => [
          { 'arn' => 'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:6' }
        ]
      }
    ]
  end

  describe '#plan_cleanup' do
    it 'retains latest N versions and protects referenced versions outside latest N' do
      cleaner = described_class.new(
        application: application,
        layer_name: 'shared_libs',
        retain_limit: 3,
        dry_run: true
      )

      # v3 は古い（4番目）だが、api_handler から参照されている
      references_map = {
        'arn:aws:lambda:ap-northeast-1:123456789012:layer:cleaner-test-app-shared_libs:3' => ['function:api_handler']
      }

      plan = cleaner.plan_cleanup(mock_versions, references_map)

      # 最新3個 (v6, v5, v4) は latest として保持
      retained_latest = plan[:retained].select { |i| i['status'] == 'retained_as_latest' }
      expect(retained_latest.map { |i| i['version'] }).to eq([6, 5, 4])

      # v3 は参照されているため保護
      expect(plan[:referenced].map { |i| i['version'] }).to eq([3])
      expect(plan[:referenced].first['references']).to eq(['function:api_handler'])
      expect(plan[:referenced].first['status']).to eq('retained_as_referenced')

      # v2, v1 は古く参照もないため削除対象
      expect(plan[:to_prune].map { |i| i['version'] }).to eq([2, 1])
      expect(plan[:to_prune].all? { |i| i['status'] == 'to_prune' }).to be true
    end
  end

  describe '#prune' do
    let(:aws_client) { double('Aws::Lambda::Client') }

    before do
      allow(aws_client).to receive(:list_layer_versions)
        .with(layer_name: anything)
        .and_return(double('ListLayerVersionsResponse', layer_versions: mock_versions.map do |v|
          double(
            'Version',
            version: v['version'],
            layer_version_arn: v['layer_version_arn'],
            created_date: v['created_date'],
            description: v['description']
          )
        end))

      allow(aws_client).to receive(:list_functions)
        .and_return(double('ListFunctionsResponse', functions: mock_functions.map do |f|
          double(
            'Function',
            function_name: f['function_name'],
            layers: f['layers'].map { |l| double('LayerObj', arn: l['arn']) }
          )
        end))

      allow(aws_client).to receive(:delete_layer_version)
    end

    context 'with dry_run: true' do
      it 'identifies prune candidates and references without deleting from AWS' do
        report = described_class.prune(
          application: application,
          layer_name: 'shared_libs',
          aws_client: aws_client,
          dry_run: true
        )

        expect(aws_client).not_to have_received(:delete_layer_version)
        expect(report.dry_run?).to be true
        expect(report.layer_name).to eq('shared_libs')
        expect(report.retained_limit).to eq(3)

        # サマリーの検証
        expect(report.summary['total_versions']).to eq(6)
        expect(report.summary['retained_count']).to eq(4) # latest 3 + referenced 1
        expect(report.summary['referenced_count']).to eq(1)
        expect(report.summary['pruned_count']).to eq(2) # v2, v1

        # 削除候補の検証
        to_prune_versions = report.pruned_versions.map { |v| v['version'] }
        expect(to_prune_versions).to eq([2, 1])

        # 保持バージョンの検証
        retained_versions = report.retained_versions.map { |v| v['version'] }
        expect(retained_versions).to eq([6, 5, 4, 3])
      end
    end

    context 'with dry_run: false' do
      it 'deletes eligible unreferenced old versions from AWS' do
        report = described_class.prune(
          application: application,
          layer_name: 'shared_libs',
          aws_client: aws_client,
          dry_run: false
        )

        # v2 と v1 が削除される
        expect(aws_client).to have_received(:delete_layer_version)
          .with(layer_name: anything, version_number: 2)
        expect(aws_client).to have_received(:delete_layer_version)
          .with(layer_name: anything, version_number: 1)

        # v3, v4, v5, v6 は削除されない
        expect(aws_client).not_to have_received(:delete_layer_version)
          .with(layer_name: anything, version_number: 3)
        expect(aws_client).not_to have_received(:delete_layer_version)
          .with(layer_name: anything, version_number: 6)

        expect(report.pruned_versions.map { |v| v['status'] }).to eq(%w[pruned pruned])
        expect(report.summary['pruned_count']).to eq(2)
      end
    end

    context 'in production environment' do
      let(:prod_application) do
        Veltrunode::Model::Application.new(
          name: 'cleaner-prod-app',
          stage: 'prod',
          region: 'ap-northeast-1',
          layers: [layer]
        )
      end

      it 'raises ConfirmationRequiredError when confirm flag is false and non-interactive' do
        expect do
          described_class.prune(
            application: prod_application,
            layer_name: 'shared_libs',
            aws_client: aws_client,
            dry_run: false,
            confirm: false,
            prompt_in: nil
          )
        end.to raise_error(Veltrunode::AWS::LayerCleaner::ConfirmationRequiredError)

        expect(aws_client).not_to have_received(:delete_layer_version)
      end

      it 'allows pruning when confirm: true is explicitly provided' do
        report = described_class.prune(
          application: prod_application,
          layer_name: 'shared_libs',
          aws_client: aws_client,
          dry_run: false,
          confirm: true
        )

        expect(report.summary['pruned_count']).to eq(2)
        expect(aws_client).to have_received(:delete_layer_version).twice
      end

      it 'allows pruning in production during dry-run without confirm flag' do
        report = described_class.prune(
          application: prod_application,
          layer_name: 'shared_libs',
          aws_client: aws_client,
          dry_run: true,
          confirm: false
        )

        expect(report.dry_run?).to be true
        expect(report.summary['pruned_count']).to eq(2)
        expect(aws_client).not_to have_received(:delete_layer_version)
      end

      it 'prompts for confirmation when prompt IO is interactive and user inputs y' do
        prompt_in = StringIO.new("y\n")
        allow(prompt_in).to receive(:tty?).and_return(true)
        prompt_out = StringIO.new

        report = described_class.prune(
          application: prod_application,
          layer_name: 'shared_libs',
          aws_client: aws_client,
          dry_run: false,
          confirm: false,
          prompt_in: prompt_in,
          prompt_out: prompt_out
        )

        expect(prompt_out.string).to include('WARNING: You are about to prune layer versions in production')
        expect(report.summary['pruned_count']).to eq(2)
        expect(aws_client).to have_received(:delete_layer_version).twice
      end

      it 'aborts and raises error when user rejects prompt' do
        prompt_in = StringIO.new("n\n")
        allow(prompt_in).to receive(:tty?).and_return(true)
        prompt_out = StringIO.new

        expect do
          described_class.prune(
            application: prod_application,
            layer_name: 'shared_libs',
            aws_client: aws_client,
            dry_run: false,
            confirm: false,
            prompt_in: prompt_in,
            prompt_out: prompt_out
          )
        end.to raise_error(Veltrunode::AWS::LayerCleaner::ConfirmationRequiredError)

        expect(aws_client).not_to have_received(:delete_layer_version)
      end
    end

    context 'when layer does not exist in application' do
      it 'raises ArgumentError' do
        expect do
          described_class.prune(
            application: application,
            layer_name: 'non_existent_layer',
            aws_client: aws_client
          )
        end.to raise_error(ArgumentError, /Layer 'non_existent_layer' not found/)
      end
    end

    context 'when no published versions exist' do
      it 'returns an empty report with 0 counts' do
        empty_aws_client = double('Aws::Lambda::Client')
        allow(empty_aws_client).to receive(:list_layer_versions)
          .and_return(double('ListLayerVersionsResponse', layer_versions: []))

        report = described_class.prune(
          application: application,
          layer_name: 'shared_libs',
          aws_client: empty_aws_client,
          dry_run: true
        )

        expect(report.summary['total_versions']).to eq(0)
        expect(report.summary['pruned_count']).to eq(0)
        expect(report.versions).to be_empty
      end
    end
  end
end
