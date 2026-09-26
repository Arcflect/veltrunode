# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'stringio'
require 'json'
require 'tmpdir'
require 'veltrunode/cli'
require 'veltrunode/dsl/secret_value'

RSpec.describe 'CLI --format json output and secret masking' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  before do
    allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
    allow($stdout).to receive(:print) { |val| stdout.print(val) }
    allow($stdout).to receive(:flush)
    allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    Veltrunode::DSL::SecretValue.clear_registry!
  end

  after do
    Veltrunode::DSL::SecretValue.clear_registry!
  end

  def run_cli(args)
    stdout.string.clear
    stderr.string.clear
    Veltrunode::CLI::Router.run(args)
  end

  describe '全コマンドでの共通スキーマ検証と jq パース可能性' do
    let(:mock_app) do
      fn = Veltrunode::Model::Function.new(:test_fn, handler: 'test.handler')
      Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
    end

    before do
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)
    end

    it 'init コマンドで共通スキーマを満たし jq でパース可能であること' do
      mock_gen = Veltrunode::Generator::Result.new(
        created_files: ['Veltrunodefile'],
        skipped_files: [],
        target_dir: '.'
      )
      allow(Veltrunode::Generator).to receive(:run).and_return(mock_gen)

      code = run_cli(%w[init --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('init')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['created_files']).to eq(['Veltrunodefile'])

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'validate コマンドで共通スキーマを満たし jq でパース可能であること' do
      allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])

      code = run_cli(%w[validate --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('validate')
      expect(parsed['status']).to eq('success')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'build コマンドで共通スキーマを満たし jq でパース可能であること' do
      mock_build_result = Veltrunode::Build::BuildResult.new(
        application: mock_app,
        function_results: [],
        layer_results: [],
        template_path: 'build/template.yml',
        template_data: {},
        manifest_path: 'build/manifest.json',
        manifest_data: {}
      )
      allow(Veltrunode::Build::Pipeline).to receive(:execute).and_return(mock_build_result)

      code = run_cli(%w[build --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('build')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['template_path']).to eq('build/template.yml')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'plan コマンドで共通スキーマを満たし jq でパース可能であること' do
      mock_build_result = Veltrunode::Build::BuildResult.new(
        application: mock_app,
        function_results: [],
        layer_results: [],
        template_path: 'build/template.yml',
        template_data: {},
        manifest_path: 'build/manifest.json',
        manifest_data: {}
      )
      allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])
      allow(Veltrunode::Build::Pipeline).to receive(:execute).and_return(mock_build_result)

      mock_cs_result = instance_double(
        Veltrunode::AWS::ChangeSetResult,
        stack_name: 'demo-stack',
        change_set_name: 'cs-123',
        summary: { add: 1, modify: 0, replace: 0, remove: 0 },
        changes: []
      )
      mock_manager = instance_double(Veltrunode::AWS::ChangeSetManager)
      allow(Veltrunode::AWS::ChangeSetManager).to receive(:new).and_return(mock_manager)
      allow(mock_manager).to receive(:create_and_describe_change_set).and_return(mock_cs_result)

      code = run_cli(%w[plan --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('plan')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['stack_name']).to eq('demo-stack')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'deploy コマンドで共通スキーマを満たし jq でパース可能であること' do
      allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
      mock_deploy_result = Veltrunode::Deploy::DeployResult.new(
        status: :success,
        message: 'Deployment complete',
        stack_name: 'demo-stack',
        change_set_name: 'cs-123',
        summary: { add: 1 },
        events: []
      )
      allow(Veltrunode::Deploy::Pipeline).to receive(:execute).and_return(mock_deploy_result)

      code = run_cli(%w[deploy --yes --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('deploy')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['stack_name']).to eq('demo-stack')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'deploy コマンドのロールバック失敗時に共通スキーマを満たし diagnostics にロールバック診断情報が含まれること' do
      diag = Veltrunode::Diagnostics::Diagnostic.new(
        code: 'VLT-CFN-ROLLBACK-IAM',
        severity: :error,
        summary: "Resource 'WorkerFunction' (AWS::Lambda::Function) failed: AccessDenied",
        suggested_action: "Ensure the deployment IAM role or user has permission for 'lambda:CreateFunction'. " \
                          'Check IAM policies and retry.',
        evidence: {
          'logical_resource_id' => 'WorkerFunction',
          'resource_type' => 'AWS::Lambda::Function',
          'resource_status' => 'CREATE_FAILED'
        },
        aws_resource_id: 'WorkerFunction'
      )
      mock_failed_deploy_result = Veltrunode::Deploy::DeployResult.new(
        status: :error,
        exit_code: 7,
        message: "Stack update failed: Stack 'demo-stack' deployment failed with status 'ROLLBACK_COMPLETE'",
        diagnostics: [diag]
      )
      allow(Veltrunode::Deploy::Pipeline).to receive(:execute).and_return(mock_failed_deploy_result)

      code = run_cli(%w[deploy --yes --format json])
      expect(code).to eq(7)

      raw = stderr.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('deploy')
      expect(parsed['status']).to eq('error')
      expect(parsed['diagnostics'].size).to eq(1)
      expect(parsed['diagnostics'].first['code']).to eq('VLT-CFN-ROLLBACK-IAM')
      expect(parsed['diagnostics'].first['suggested_action']).to include('lambda:CreateFunction')
      expect(parsed['diagnostics'].first['aws_resource_id']).to eq('WorkerFunction')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'destroy コマンドで共通スキーマを満たし jq でパース可能であること' do
      allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
      mock_destroyer = instance_double(Veltrunode::AWS::StackDestroyer)
      allow(Veltrunode::AWS::StackDestroyer).to receive(:new).and_return(mock_destroyer)
      allow(mock_destroyer).to receive(:stack_exists?).and_return(true)
      allow(mock_destroyer).to receive(:describe_stack_resources).and_return([])
      allow(mock_destroyer).to receive(:delete_stack)
      allow(mock_destroyer).to receive(:wait_for_stack_deletion).and_return([])

      code = run_cli(%w[destroy --yes --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('destroy')
      expect(parsed['status']).to eq('success')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'invoke local コマンドで共通スキーマを満たし jq でパース可能であること' do
      mock_exec_result = Veltrunode::Runner::ExecutionResult.new(
        result: { 'status' => 'ok' },
        warnings: [],
        duration_ms: 12.3,
        memory_size_mb: 128,
        function_name: 'test_fn'
      )
      allow(Veltrunode::Runner).to receive(:run).and_return(mock_exec_result)

      code = run_cli(%w[invoke local test_fn --format json])
      expect(code).to eq(0)

      raw = stdout.string.strip
      parsed = JSON.parse(raw)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('invoke local')
      expect(parsed['status']).to eq('success')
      expect(parsed['data']['result']).to eq({ 'status' => 'ok' })

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
      expect(status.success?).to be true
    end

    it 'version, help, efs, layer, schedule で共通スキーマを満たし jq でパース可能であること' do
      commands = [
        { args: ['--version', '--format', 'json'], expected_cmd: 'version' },
        { args: ['--help', '--format', 'json'], expected_cmd: 'help' },
        { args: ['efs', 'verify', 'my_efs', '--format', 'json'], expected_cmd: 'efs verify' },
        { args: ['layer', 'inspect', 'my_layer', '--format', 'json'], expected_cmd: 'layer inspect' },
        { args: ['schedule', 'preview', 'my_sched', '--format', 'json'], expected_cmd: 'schedule preview' }
      ]

      commands.each do |tc|
        code = run_cli(tc[:args])
        expect(code).to eq(0)

        raw = stdout.string.strip
        parsed = JSON.parse(raw)
        expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
        expect(parsed['command']).to eq(tc[:expected_cmd])
        expect(parsed['status']).to eq('success')

        _out, _err, status = Open3.capture3('jq .', stdin_data: raw)
        expect(status.success?).to be true
      end
    end
  end

  describe 'エラー発生時の共通スキーマ検証' do
    it '未知のコマンドに対して共通スキーマのエラーJSONを出力し jq でパース可能であること' do
      code = run_cli(%w[non_existing_cmd --format json])
      expect(code).to eq(2)

      raw_json = stderr.string.strip
      expect(raw_json).not_to be_empty

      parsed = JSON.parse(raw_json)
      expect(parsed.keys).to contain_exactly('command', 'status', 'diagnostics', 'data')
      expect(parsed['command']).to eq('unknown')
      expect(parsed['status']).to eq('error')
      expect(parsed['diagnostics']).to be_an(Array)
      expect(parsed['data']).to be_a(Hash)
      expect(parsed['data']['error_code']).to eq(2)
      expect(parsed['data']['message']).to include("Unknown command 'non_existing_cmd'")

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw_json)
      expect(status.success?).to be true
    end
  end

  describe '機密情報（env() で secret マークされた値）の自動マスク検証' do
    it 'SecretValue オブジェクトおよび登録された秘密文字列が [FILTERED] にマスクされること' do
      secret_token = 'super-secret-token-abcdef123456'
      Veltrunode::DSL::SecretValue.new(secret_token)

      mock_app = Veltrunode::Model::Application.new(name: 'demo_app')
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)

      code = run_cli(['efs', 'verify', "efs-with-#{secret_token}", '--format', 'json'])
      expect(code).to eq(0)

      raw_json = stdout.string.strip
      expect(raw_json).not_to include(secret_token)
      expect(raw_json).to include('[FILTERED]')

      parsed = JSON.parse(raw_json)
      expect(parsed['data']['message']).to eq('EFS verification successful for: efs-with-[FILTERED]')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw_json)
      expect(status.success?).to be true
    end

    it 'エラーメッセージに機密情報が含まれる場合も自動マスクされること' do
      secret_password = 'db-secret-password-xyz999'
      Veltrunode::DSL::SecretValue.new(secret_password)

      mock_app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [])
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)

      code = run_cli(['invoke', 'local', "func-#{secret_password}", '--format', 'json'])
      expect(code).to eq(2)

      raw_json = stderr.string.strip
      expect(raw_json).not_to include(secret_password)
      expect(raw_json).to include('[FILTERED]')

      parsed = JSON.parse(raw_json)
      expect(parsed['data']['message']).to include('[FILTERED]')

      _out, _err, status = Open3.capture3('jq .', stdin_data: raw_json)
      expect(status.success?).to be true
    end
  end
end
