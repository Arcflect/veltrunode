# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/efs_inspector'

RSpec.describe 'CLI veltrunode efs verify NAME' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:efs_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0',
      local_path: '/mnt/shared',
      posix_expectations: { uid: 1000, gid: 1000 }
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      :processor,
      handler: 'app.handler',
      vpc_reference: {
        security_group_ids: ['sg-lambda123'],
        subnet_ids: ['subnet-aaa']
      },
      mounts: ['shared_data']
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-test-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      mounts: [efs_mount],
      functions: [function]
    )
  end

  let(:mock_report_success) do
    check = Veltrunode::AWS::Inspectors::EfsInspector::CheckResult.new(
      name: 'access_point_status',
      status: :passed,
      confidence: 'HIGH',
      summary: 'Access point fsap-1234567890abcdef0 is available.',
      evidence: { 'life_cycle_state' => 'available' }
    )
    Veltrunode::AWS::Inspectors::EfsInspector::Report.new(
      target_name: 'shared_data',
      function_name: 'processor',
      access_point_id: 'fsap-1234567890abcdef0',
      file_system_id: 'fs-12345678',
      checks: [check],
      diagnostics: [],
      overall_confidence: 'HIGH'
    )
  end

  let(:mock_report_failed) do
    diag = Veltrunode::Diagnostics::Diagnostic.new(
      code: 'VLT-EFS-2049-INGRESS',
      severity: :error,
      summary: 'EFS security group sg-efs does not allow TCP 2049 from Lambda security group sg-lambda.',
      suggested_action: 'add an ingress rule scoped to sg-lambda, ' \
                        'or reference a security group that already provides it.',
      evidence: { 'efs_security_groups' => ['sg-efs'], 'lambda_security_groups' => ['sg-lambda'] },
      aws_resource_id: 'sg-efs'
    )
    check = Veltrunode::AWS::Inspectors::EfsInspector::CheckResult.new(
      name: 'security_group_ingress',
      status: :failed,
      confidence: 'HIGH',
      summary: 'EFS security group sg-efs denies TCP 2049 from sg-lambda.',
      evidence: { 'efs_security_groups' => ['sg-efs'] },
      diagnostic: diag
    )
    Veltrunode::AWS::Inspectors::EfsInspector::Report.new(
      target_name: 'shared_data',
      function_name: 'processor',
      access_point_id: 'fsap-1234567890abcdef0',
      file_system_id: 'fs-12345678',
      checks: [check],
      diagnostics: [diag],
      overall_confidence: 'LOW'
    )
  end

  before do
    allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
    allow($stdout).to receive(:print) { |val| stdout.print(val) }
    allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    allow(Veltrunode::SettingsLoader).to receive(:load).and_return(application)
  end

  def run_cli(args)
    stdout.string.clear
    stderr.string.clear
    Veltrunode::CLI::Router.run(args)
  end

  describe 'テキスト出力モード（デフォルト）' do
    it '全チェック成功時に終了コード 0 を返し、証拠・確信度・制限事項を含むレポートを出力すること' do
      allow(Veltrunode::AWS::Inspectors::EfsInspector).to receive(:inspect).and_return(mock_report_success)

      code = run_cli(%w[efs verify shared_data])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Veltrunode EFS Verification Report')
      expect(output).to include('Target:              shared_data')
      expect(output).to include('Overall Confidence:  HIGH')
      expect(output).to include('[PASSED]  Access Point Status (confidence: HIGH)')
      expect(output).to include('Diagnostic Limitations:')
      expect(output).to include('Network Access Control Lists (NACLs)')
      expect(output).to include('Status: SUCCESS')
    end

    it 'チェック失敗時に終了コード 3 を返し、エラーコードと推奨アクションを出力すること' do
      allow(Veltrunode::AWS::Inspectors::EfsInspector).to receive(:inspect).and_return(mock_report_failed)

      code = run_cli(%w[efs verify shared_data])

      expect(code).to eq(3)
      output = stdout.string
      expect(output).to include('[FAILED]  EFS Security Group Inbound (TCP 2049 Ingress) (confidence: HIGH)')
      expect(output).to include(
        'VLT-EFS-2049-INGRESS: EFS security group sg-efs does not allow TCP 2049 ' \
        'from Lambda security group sg-lambda.'
      )
      expect(output).to include(
        'Suggested action: add an ingress rule scoped to sg-lambda, ' \
        'or reference a security group that already provides it.'
      )
      expect(output).to include('Status: FAILED (1 errors, 0 warnings)')
    end
  end

  describe 'JSON 出力モード (--format json)' do
    it '共通スキーマに準拠した JSON を出力し、終了コード 0 を返すこと' do
      allow(Veltrunode::AWS::Inspectors::EfsInspector).to receive(:inspect).and_return(mock_report_success)

      code = run_cli(%w[efs verify shared_data --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)
      expect(parsed['command']).to eq('efs verify')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics']).to be_empty
      expect(parsed['data']['target']).to eq('shared_data')
      expect(parsed['data']['function']).to eq('processor')
      expect(parsed['data']['overall_confidence']).to eq('HIGH')
      expect(parsed['data']['limitations']).to be_an(Array)
      expect(parsed['data']['checks'].first['name']).to eq('access_point_status')
    end

    it 'エラー時に status: error と diagnostics を含む JSON を出力し、終了コード 3 を返すこと' do
      allow(Veltrunode::AWS::Inspectors::EfsInspector).to receive(:inspect).and_return(mock_report_failed)

      code = run_cli(%w[efs verify shared_data --format json])

      expect(code).to eq(3)
      parsed = JSON.parse(stdout.string.strip)
      expect(parsed['command']).to eq('efs verify')
      expect(parsed['status']).to eq('error')
      expect(parsed['diagnostics'].size).to eq(1)
      expect(parsed['diagnostics'].first['code']).to eq('VLT-EFS-2049-INGRESS')
      expect(parsed['diagnostics'].first['suggested_action']).to include('add an ingress rule scoped to sg-lambda')
    end
  end
end
