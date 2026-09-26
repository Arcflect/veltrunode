# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/cli'
require 'stringio'

RSpec.describe Veltrunode::CLI::Router do
  describe '.run' do
    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }

    before do
      # Avoid modifying the actual stdout/stderr streams
      allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
      allow($stdout).to receive(:print) { |val| stdout.print(val) }
      allow($stdout).to receive(:flush)
      allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(Veltrunode::Application.new('test-app'))
    end

    def run_cli(args)
      stdout.string.clear
      stderr.string.clear
      Veltrunode::CLI::Router.run(args)
    end

    it 'displays help when no arguments are provided' do
      code = run_cli([])
      expect(code).to eq(0)
      expect(stdout.string).to include('Usage:')
    end

    it 'displays help when --help is provided' do
      code = run_cli(['--help'])
      expect(code).to eq(0)
      expect(stdout.string).to include('Usage:')
    end

    it 'displays version when --version is provided' do
      code = run_cli(['--version'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq(Veltrunode::VERSION)
    end

    it 'displays version in JSON format when --format json is provided' do
      code = run_cli(['--version', '--format', 'json'])
      expect(code).to eq(0)
      json = JSON.parse(stdout.string)
      expect(json['command']).to eq('version')
      expect(json['status']).to eq('success')
      expect(json['data']['version']).to eq(Veltrunode::VERSION)
    end

    it 'returns exit code 2 and error message for unknown command' do
      code = run_cli(['invalid_subcommand'])
      expect(code).to eq(2)
      expect(stderr.string).to include("Unknown command 'invalid_subcommand'")
    end

    describe 'init command' do
      let(:mock_gen_result) do
        Veltrunode::Generator::Result.new(
          created_files: %w[Veltrunodefile Gemfile .gitignore functions/app.rb],
          skipped_files: [],
          target_dir: '/path/to/app'
        )
      end

      before do
        allow(Veltrunode::Generator).to receive(:run).and_return(mock_gen_result)
      end

      it 'runs init command with default runtime and displays created files' do
        code = run_cli(['init'])
        expect(code).to eq(0)
        expect(stdout.string).to include('Project initialized successfully.')
        expect(stdout.string).to include('Created files:')
        expect(stdout.string).to include('- Veltrunodefile')
        expect(stdout.string).to include('- functions/app.rb')
        expect(Veltrunode::Generator).to have_received(:run).with('.', runtime: 'ruby')
      end

      it 'passes target directory and --runtime option to Generator' do
        code = run_cli(%w[init my_new_app --runtime python3.12])
        expect(code).to eq(0)
        expect(Veltrunode::Generator).to have_received(:run).with('my_new_app', runtime: 'python3.12')
      end

      it 'outputs structured JSON when --format json is specified' do
        code = run_cli(['init', '--format', 'json'])
        expect(code).to eq(0)
        json = JSON.parse(stdout.string)
        expect(json['command']).to eq('init')
        expect(json['status']).to eq('success')
        expect(json['data']['message']).to eq('Project initialized successfully.')
        expect(json['data']['created_files']).to eq(%w[Veltrunodefile Gemfile .gitignore functions/app.rb])
        expect(json['data']['skipped_files']).to eq([])
        expect(json['data']['target_dir']).to eq('/path/to/app')
      end

      it 'displays skipped files when Generator skips existing files' do
        skip_result = Veltrunode::Generator::Result.new(
          created_files: ['functions/app.rb'],
          skipped_files: ['Veltrunodefile'],
          target_dir: '/path/to/app'
        )
        allow(Veltrunode::Generator).to receive(:run).and_return(skip_result)

        code = run_cli(['init'])
        expect(code).to eq(0)
        expect(stdout.string).to include('Created files:')
        expect(stdout.string).to include('- functions/app.rb')
        expect(stdout.string).to include('Skipped files (already exists):')
        expect(stdout.string).to include('- Veltrunodefile')
      end
    end

    describe 'validate command' do
      let(:valid_app) do
        Veltrunode::Model::Application.new(
          name: 'valid-app',
          region: 'ap-northeast-1',
          stage: 'dev'
        )
      end

      before do
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(valid_app)
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])
      end

      it 'returns exit code 0 on successful validation' do
        code = run_cli(['validate'])
        expect(code).to eq(0)
        expect(stdout.string).to include('Validation successful.')
        expect(Veltrunode::Validation::Engine).to have_received(:run).with(
          valid_app,
          source_dir: Dir.pwd
        )
      end

      it 'passes source_dir when --file option is specified' do
        code = run_cli(['validate', '--file', '/custom/path/Veltrunodefile'])
        expect(code).to eq(0)
        expect(Veltrunode::Validation::Engine).to have_received(:run).with(
          valid_app,
          source_dir: '/custom/path'
        )
      end

      it 'returns exit code 3 with error diagnostics on validation failure' do
        error_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-INVALID-NAME',
          severity: :error,
          summary: 'Invalid resource name.',
          suggested_action: 'Fix name.'
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([error_diag])

        code = run_cli(['validate'])
        expect(code).to eq(3)
        expect(stdout.string).to include('[ERROR] [VLT-DSL-INVALID-NAME] Invalid resource name.')
        expect(stderr.string).to include('Validation failed with 1 error(s).')
      end

      it 'outputs structured JSON on success when --format json is provided' do
        code = run_cli(['validate', '--format', 'json'])
        expect(code).to eq(0)
        json = JSON.parse(stdout.string)
        expect(json['command']).to eq('validate')
        expect(json['status']).to eq('success')
        expect(json['data']['errors_count']).to eq(0)
        expect(json['data']['warnings_count']).to eq(0)
        expect(json['diagnostics']).to eq([])
      end

      it 'outputs structured JSON on error when --format json is provided' do
        error_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-BUILD-HANDLER-NOT-FOUND',
          severity: :error,
          summary: 'Handler file app.rb not found.',
          suggested_action: 'Create app.rb.'
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([error_diag])

        code = run_cli(['validate', '--format', 'json'])
        expect(code).to eq(3)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('validate')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(3)
        expect(json['data']['errors_count']).to eq(1)
        expect(json['diagnostics'].first['code']).to eq('VLT-BUILD-HANDLER-NOT-FOUND')
      end

      it 'returns exit code 8 when policy violation error is detected in text format' do
        policy_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-IAM-001',
          severity: :error,
          summary: 'Wildcard IAM action is denied by stage policy.',
          suggested_action: 'Specify explicit IAM actions.',
          evidence: { 'policy_violation' => true }
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([policy_diag])

        code = run_cli(['validate'])
        expect(code).to eq(8)
        expect(stdout.string).to include('[ERROR] [VLT-IAM-001] Wildcard IAM action is denied by stage policy.')
        expect(stderr.string).to include('Validation failed with 1 error(s).')
      end

      it 'returns exit code 8 with structured JSON when policy violation error is detected with --format json' do
        policy_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-IAM-001',
          severity: :error,
          summary: 'Wildcard IAM action is denied by stage policy.',
          suggested_action: 'Specify explicit IAM actions.',
          evidence: { 'policy_violation' => true }
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([policy_diag])

        code = run_cli(['validate', '--format', 'json'])
        expect(code).to eq(8)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('validate')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(8)
        expect(json['diagnostics'].first['code']).to eq('VLT-IAM-001')
      end

      describe 'with --aws option' do
        it 'invokes ConnectionInspector and passes when AWS check succeeds' do
          require 'veltrunode/aws/inspectors/connection_inspector'
          allow(Veltrunode::AWS::Inspectors::ConnectionInspector).to receive(:inspect).and_return([])

          code = run_cli(['validate', '--aws'])
          expect(code).to eq(0)
          expect(stdout.string).to include('Validation successful.')
          expect(Veltrunode::AWS::Inspectors::ConnectionInspector).to have_received(:inspect).with(valid_app)
        end

        it 'fails with exit code 3 when ConnectionInspector reports an error' do
          require 'veltrunode/aws/inspectors/connection_inspector'
          aws_error = Veltrunode::Diagnostics::Diagnostic.new(
            code: 'VLT-AWS-ACCOUNT-001',
            severity: :error,
            summary: 'AWS account mismatch.',
            suggested_action: 'Switch credentials.'
          )
          allow(Veltrunode::AWS::Inspectors::ConnectionInspector).to receive(:inspect).and_return([aws_error])

          code = run_cli(['validate', '--aws'])
          expect(code).to eq(3)
          expect(stdout.string).to include('[ERROR] [VLT-AWS-ACCOUNT-001] AWS account mismatch.')
          expect(stderr.string).to include('Validation failed with 1 error(s).')
        end
      end
    end

    describe 'build command' do
      let(:mock_fn) do
        Veltrunode::Model::Function.new(
          logical_name: 'func1',
          handler: 'f.h',
          runtime: 'ruby3.3'
        )
      end

      let(:mock_layer) do
        Veltrunode::Model::Layer.new(
          name: 'gems',
          compatible_runtimes: %w[ruby3.2 ruby3.3]
        )
      end

      let(:mock_app) do
        instance_double(
          Veltrunode::Application,
          name: 'test-app',
          region: 'ap-northeast-1',
          stage: 'dev',
          account_constraint: nil,
          schedules: [],
          functions: [mock_fn],
          layers: [mock_layer],
          mounts: [],
          policies: [],
          runtime_defaults: {}
        )
      end

      let(:mock_fn_pkg_result) do
        instance_double(
          Veltrunode::Build::PackageResult,
          function_name: 'func1',
          content_hash: 'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0',
          sha256: '9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba',
          zip_path: 'build/artifacts/functions/func1.zip',
          bytesize: 1234,
          cached?: false,
          diagnostics: []
        )
      end

      let(:mock_layer_pkg_result) do
        instance_double(
          Veltrunode::Build::LayerPackageResult,
          layer_name: 'gems',
          content_hash: 'c3d4e5f6a1b27890123456789abcdef0123456789abcdef0123456789abcdef0',
          sha256: 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
          zip_path: 'build/artifacts/layers/gems.zip',
          bytesize: 4567,
          cached?: false,
          diagnostics: []
        )
      end

      before do
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)
        allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_return(mock_fn_pkg_result)
        allow(Veltrunode::Build::LayerPackager).to receive(:package).and_return(mock_layer_pkg_result)
      end

      it 'runs build command, packages application functions and layers, and outputs hashes' do
        code = run_cli(['build'])
        expect(code).to eq(0)
        expect(stdout.string).to include('Build successful.')
        expect(stdout.string).to include('Generated artifacts:')
        expect(stdout.string).to include('func1: build/artifacts/functions/func1.zip')
        expect(stdout.string).to include('9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba')
        expect(stdout.string).to include('gems: build/artifacts/layers/gems.zip')
        expect(stdout.string).to include('fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210')
        expect(stdout.string).to include('Template:')
        expect(stdout.string).to include('Manifest:')
        expect(File.exist?(File.join(Dir.pwd, 'build', 'template.yml'))).to be true
        expect(File.exist?(File.join(Dir.pwd, 'build', 'manifest.json'))).to be true
        expect(Veltrunode::Build::FunctionPackager).to have_received(:package).with(
          hash_including(no_cache: false)
        )
        expect(Veltrunode::Build::LayerPackager).to have_received(:package).with(
          hash_including(no_cache: false)
        )
      end

      it 'runs build command with --no-cache flag' do
        code = run_cli(['build', '--no-cache'])
        expect(code).to eq(0)
        expect(stdout.string).to include('Build successful.')
        expect(Veltrunode::Build::FunctionPackager).to have_received(:package).with(
          hash_including(no_cache: true)
        )
        expect(Veltrunode::Build::LayerPackager).to have_received(:package).with(
          hash_including(no_cache: true)
        )
      end

      it 'runs build command with --format json and outputs structured JSON' do
        code = run_cli(['build', '--format', 'json'])
        expect(code).to eq(0)
        json = JSON.parse(stdout.string)
        expect(json['command']).to eq('build')
        expect(json['status']).to eq('success')
        expect(json['data']['functions_count']).to eq(1)
        expect(json['data']['layers_count']).to eq(1)
        expect(json['data']['artifacts']['functions'].first['sha256']).to eq(
          '9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba'
        )
        expect(json['data']['artifacts']['layers'].first['sha256']).to eq(
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
        )
        expect(json['data']['template_path']).to end_with('template.yml')
        expect(json['data']['manifest_path']).to end_with('manifest.json')
      end

      it 'runs build command with --bucket option and invokes S3Uploader' do
        mock_uploader = instance_double(Veltrunode::AWS::S3Uploader)
        allow(Veltrunode::AWS::S3Uploader).to receive(:new).with(
          bucket: 'my-cli-bucket',
          application: anything
        ).and_return(mock_uploader)
        allow(mock_uploader).to receive(:upload_and_update_template)

        code = run_cli(['build', '--bucket', 'my-cli-bucket'])
        expect(code).to eq(0)
        expect(mock_uploader).to have_received(:upload_and_update_template)
      end

      it 'aborts and returns exit code 3 on validation failure in text format' do
        diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-LAYER-001',
          severity: :error,
          summary: 'Function uses incompatible runtime with Layer.',
          suggested_action: 'Fix runtime incompatibility.'
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([diag])

        code = run_cli(['build'])
        expect(code).to eq(3)
        expect(stdout.string).to include('[ERROR] [VLT-LAYER-001] Function uses incompatible runtime with Layer.')
        expect(stderr.string).to include('Validation failed with 1 error(s).')
        expect(Veltrunode::Build::FunctionPackager).not_to have_received(:package)
      end

      it 'aborts and returns exit code 3 with structured JSON on validation failure with --format json' do
        diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-LAYER-001',
          severity: :error,
          summary: 'Function uses incompatible runtime with Layer.',
          suggested_action: 'Fix runtime incompatibility.'
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([diag])

        code = run_cli(['build', '--format', 'json'])
        expect(code).to eq(3)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('build')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(3)
        expect(json['diagnostics'].first['code']).to eq('VLT-LAYER-001')
      end

      it 'returns exit code 5 on build failure in text format' do
        allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_raise(RuntimeError, 'Archive error')

        code = run_cli(['build'])
        expect(code).to eq(5)
        expect(stderr.string).to include('Error: Build failed: Archive error')
      end

      it 'returns exit code 5 with structured JSON on build failure with --format json' do
        allow(Veltrunode::Build::FunctionPackager).to receive(:package).and_raise(RuntimeError, 'Archive error')

        code = run_cli(['build', '--format', 'json'])
        expect(code).to eq(5)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('build')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(5)
        expect(json['data']['message']).to include('Build failed: Archive error')
      end
    end

    describe 'plan command' do
      let(:mock_fn) do
        Veltrunode::Model::Function.new(
          logical_name: 'api_fn',
          handler: 'api.handler',
          iam_capabilities: [{ type: :read_from_s3, params: { bucket: 'my-bucket' } }]
        )
      end
      let(:plan_app) do
        Veltrunode::Model::Application.new(
          name: 'plan-app',
          region: 'ap-northeast-1',
          stage: 'dev',
          functions: [mock_fn]
        )
      end
      let(:mock_cs_manager) { instance_double(Veltrunode::AWS::ChangeSetManager) }
      let(:sample_changes) do
        [
          Veltrunode::AWS::ResourceChange.new(
            logical_resource_id: 'ApiFnFunction',
            resource_type: 'AWS::Lambda::Function',
            action: 'Add'
          ),
          Veltrunode::AWS::ResourceChange.new(
            logical_resource_id: 'ApiFnRole',
            physical_resource_id: 'arn:aws:iam::123:role/ApiFnRole',
            resource_type: 'AWS::IAM::Role',
            action: 'Modify',
            replacement: 'Always'
          )
        ]
      end
      let(:mock_cs_result) do
        Veltrunode::AWS::ChangeSetResult.new(
          stack_name: 'plan-app-dev',
          change_set_name: 'veltrunode-plan-12345',
          changes: sample_changes
        )
      end

      before do
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(plan_app)
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])
        mock_build_result = instance_double(
          Veltrunode::Build::BuildResult,
          template_path: 'build/template.yml'
        )
        allow(Veltrunode::Build::Pipeline).to receive(:execute).and_return(mock_build_result)
        allow(Veltrunode::AWS::ChangeSetManager).to receive(:new).with(
          application: plan_app
        ).and_return(mock_cs_manager)
        allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_return(mock_cs_result)
      end

      it 'runs plan command and outputs diffs with Replace emphasis and risk notice' do
        code = run_cli(['plan'])
        expect(code).to eq(0)
        expect(stdout.string).to include(
          "Plan generated for application 'plan-app' (Stack: plan-app-dev, Change Set: veltrunode-plan-12345)."
        )
        expect(stdout.string).to include('[NOTE] Plan preview cannot eliminate all execution risks.')
        expect(stdout.string).to include('Resource Changes (Add: 1, Modify: 0, Replace: 1, Remove: 0):')
        expect(stdout.string).to include('[ADD] ApiFnFunction [AWS::Lambda::Function]')
        expect(stdout.string).to include(
          '[REPLACE *** EMPHASIS ***] ApiFnRole [AWS::IAM::Role] ' \
          '(arn:aws:iam::123:role/ApiFnRole) [Replacement: Always]'
        )
        expect(stdout.string).to include('IAM Capabilities Expansion:')
        expect(stdout.string).to include("Function 'api_fn':")
        expect(stdout.string).to include('s3:GetObject, s3:ListBucket')
      end

      it 'runs plan command with --format json and outputs expanded JSON' do
        code = run_cli(['plan', '--format', 'json'])
        expect(code).to eq(0)
        json = JSON.parse(stdout.string)
        expect(json['command']).to eq('plan')
        expect(json['status']).to eq('success')
        expect(json['data']['stack_name']).to eq('plan-app-dev')
        expect(json['data']['change_set_name']).to eq('veltrunode-plan-12345')
        expect(json['data']['summary']).to eq({ 'add' => 1, 'modify' => 0, 'replace' => 1, 'remove' => 0 })
        expect(json['data']['changes'].size).to eq(2)
        expect(json['data']['changes'].last['action']).to eq('Replace')
        expect(json['data']['changes'].last['replacement']).to eq('Always')
        expect(json['data']['warning']).to eq('Plan preview cannot eliminate all execution risks.')
        expect(json['data']['iam_capabilities']['api_fn'].first['Action']).to eq(%w[s3:GetObject s3:ListBucket])
      end

      it 'runs plan command with --bucket option and invokes S3Uploader' do
        mock_uploader = instance_double(Veltrunode::AWS::S3Uploader)
        allow(Veltrunode::AWS::S3Uploader).to receive(:new).with(
          bucket: 'my-plan-bucket',
          application: plan_app
        ).and_return(mock_uploader)
        allow(mock_uploader).to receive(:upload_and_update_template)

        code = run_cli(['plan', '--bucket', 'my-plan-bucket'])
        expect(code).to eq(0)
        expect(mock_uploader).to have_received(:upload_and_update_template)
      end

      it 'returns exit code 6 when ChangeSetManager raises ChangeSetError' do
        allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_raise(
          Veltrunode::AWS::ChangeSetError.new('CFN API error')
        )

        code = run_cli(['plan'])
        expect(code).to eq(6)
        expect(stderr.string).to include('Error: Plan failed: CFN API error')
      end

      it 'returns exit code 6 with JSON error output when --format json is provided on failure' do
        allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_raise(
          Veltrunode::AWS::ChangeSetError.new('CFN API error')
        )

        code = run_cli(['plan', '--format', 'json'])
        expect(code).to eq(6)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('plan')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(6)
        expect(json['data']['message']).to include('Plan failed: CFN API error')
      end
    end

    describe 'deploy command' do
      let(:deploy_app) do
        Veltrunode::Model::Application.new(
          name: 'deploy-app',
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
          logical_resource_id: 'DeployFunction',
          resource_type: 'AWS::Lambda::Function',
          action: 'Add'
        )
      end

      let(:mock_cs_result) do
        Veltrunode::AWS::ChangeSetResult.new(
          stack_name: 'deploy-app-prod',
          change_set_name: 'cs-deploy',
          changes: [mock_change]
        )
      end

      let(:mock_stack_event) do
        Veltrunode::AWS::StackEvent.new(
          event_id: 'ev-1',
          logical_resource_id: 'DeployFunction',
          resource_type: 'AWS::Lambda::Function',
          resource_status: 'CREATE_COMPLETE',
          timestamp: Time.now
        )
      end

      let(:mock_cs_manager) { instance_double(Veltrunode::AWS::ChangeSetManager) }

      before do
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(deploy_app)
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([])
        allow(Veltrunode::Build::Pipeline).to receive(:execute).and_return(mock_build_result)
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
        allow(Veltrunode::AWS::ChangeSetManager).to receive(:new).and_return(mock_cs_manager)
        allow(mock_cs_manager).to receive(:create_and_describe_change_set).and_return(mock_cs_result)
        allow(mock_cs_manager).to receive(:execute_change_set)
        allow(mock_cs_manager).to receive(:wait_for_stack_completion)
          .and_yield(mock_stack_event).and_return([mock_stack_event])
        allow($stdin).to receive(:tty?).and_return(false)
      end

      it 'runs deploy successfully when --yes is specified on protected stage' do
        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(0)
        expect(stdout.string).to include("Plan generated for application 'deploy-app'")
        expect(stdout.string).to include('[PROGRESS] DeployFunction [AWS::Lambda::Function] CREATE_COMPLETE')
        expect(stdout.string).to include("Deployment successful for stack 'deploy-app-prod'.")
      end

      it 'aborts deployment with exit code 7 on protected stage when --yes is not provided without tty' do
        code = run_cli(['deploy'])
        expect(code).to eq(7)
        expect(stderr.string).to include("Deployment to protected stage 'prod' cancelled by user.")
      end

      it 'proceeds with deployment on protected stage when user approves via interactive prompt' do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:gets).and_return("y\n")

        code = run_cli(['deploy'])
        expect(code).to eq(0)
        expect(stdout.string).to include("Deployment successful for stack 'deploy-app-prod'.")
      end

      it 'aborts deployment on protected stage when user rejects via interactive prompt' do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:gets).and_return("n\n")

        code = run_cli(['deploy'])
        expect(code).to eq(7)
        expect(stderr.string).to include("Deployment to protected stage 'prod' cancelled by user.")
      end

      it 'runs deploy with warning and exits 0 when account constraint is not specified' do
        warn_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-ACCOUNT-002',
          severity: :warning,
          summary: 'No account constraint specified.',
          suggested_action: 'Specify account constraint.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([warn_diag])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(0)
        expect(stdout.string).to include('[WARN] [VLT-AWS-ACCOUNT-002] No account constraint specified.')
        expect(stdout.string).to include("Deployment successful for stack 'deploy-app-prod'.")
      end

      it 'aborts deployment and returns exit code 4 on account mismatch' do
        account_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-ACCOUNT-001',
          severity: :error,
          summary: "AWS account mismatch: current '999999999999' != expected '123456789012'.",
          suggested_action: 'Switch credentials.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([account_error])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(4)
        expect(stdout.string).to include('[ERROR] [VLT-AWS-ACCOUNT-001]')
        expect(stderr.string).to include('Deployment aborted: AWS verification failed with 1 error(s).')
      end

      it 'aborts deployment and returns exit code 4 on region mismatch' do
        region_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-REGION-001',
          severity: :error,
          summary: "AWS region mismatch: configured 'us-east-1' != expected 'ap-northeast-1'.",
          suggested_action: 'Switch region.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([region_error])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(4)
        expect(stdout.string).to include('[ERROR] [VLT-AWS-REGION-001]')
        expect(stderr.string).to include('Deployment aborted: AWS verification failed with 1 error(s).')
      end

      it 'aborts deployment and returns exit code 4 on STS authentication failure' do
        auth_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-AUTH-001',
          severity: :error,
          summary: 'AWS authentication failed.',
          suggested_action: 'Verify AWS credentials.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([auth_error])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(4)
        expect(stdout.string).to include('[ERROR] [VLT-AWS-AUTH-001]')
        expect(stderr.string).to include('Deployment aborted: AWS verification failed with 1 error(s).')
      end

      it 'aborts deployment and returns exit code 3 on validation failure' do
        val_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-DSL-001',
          severity: :error,
          summary: 'Validation error.',
          suggested_action: 'Fix syntax.'
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([val_error])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(3)
        expect(stdout.string).to include('[ERROR] [VLT-DSL-001]')
        expect(stderr.string).to include('Validation failed with 1 error(s).')
      end

      it 'aborts deployment and returns exit code 8 on policy violation' do
        policy_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-IAM-001',
          severity: :error,
          summary: 'IAM policy violation.',
          suggested_action: 'Remove wildcard.',
          evidence: { 'policy_violation' => true }
        )
        allow(Veltrunode::Validation::Engine).to receive(:run).and_return([policy_error])

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(8)
        expect(stdout.string).to include('[ERROR] [VLT-IAM-001]')
        expect(stderr.string).to include('Validation failed with 1 error(s).')
      end

      it 'aborts deployment and returns exit code 5 on build failure' do
        allow(Veltrunode::Build::Pipeline).to receive(:execute).and_raise(RuntimeError.new('Docker build failed'))

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(5)
        expect(stderr.string).to include('Build failed: Docker build failed')
      end

      it 'aborts deployment and returns exit code 7 on change set execution failure' do
        allow(mock_cs_manager).to receive(:execute_change_set).and_raise(
          Veltrunode::AWS::ChangeSetError.new('Execution failed')
        )

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(7)
        expect(stderr.string).to include('Failed to execute Change Set')
      end

      it 'diagnoses rollback cause, displays error with suggested action, and exits 7 on stack update failure' do
        failed_event = Veltrunode::AWS::StackEvent.new(
          event_id: 'ev-rollback-1',
          logical_resource_id: 'WorkerFunction',
          resource_type: 'AWS::Lambda::Function',
          resource_status: 'CREATE_FAILED',
          resource_status_reason: 'User: arn:aws:iam::123:user/dev is not authorized to perform: lambda:CreateFunction'
        )
        allow(mock_cs_manager).to receive(:wait_for_stack_completion).and_raise(
          Veltrunode::AWS::ChangeSetError.new(
            "Stack 'deploy-app-prod' deployment failed with status 'ROLLBACK_COMPLETE'",
            events: [failed_event]
          )
        )

        code = run_cli(['deploy', '--yes'])
        expect(code).to eq(7)
        expect(stdout.string).to include(
          "[ERROR] [VLT-CFN-ROLLBACK-IAM] Resource 'WorkerFunction' (AWS::Lambda::Function) failed"
        )
        expect(stdout.string).to include(
          'Suggested action: Ensure the deployment IAM role or user has the necessary permissions'
        )
        expect(stdout.string).to include('lambda:CreateFunction')
        expect(stderr.string).to include('Stack update failed')
      end

      it 'returns structured JSON error with rollback diagnostics on stack update failure with --format json' do
        failed_event = Veltrunode::AWS::StackEvent.new(
          event_id: 'ev-rollback-2',
          logical_resource_id: 'WorkerFunction',
          resource_type: 'AWS::Lambda::Function',
          resource_status: 'CREATE_FAILED',
          resource_status_reason: 'ResourceLimitExceeded: Function count limit reached'
        )
        allow(mock_cs_manager).to receive(:wait_for_stack_completion).and_raise(
          Veltrunode::AWS::ChangeSetError.new(
            "Stack 'deploy-app-prod' deployment failed with status 'ROLLBACK_COMPLETE'",
            events: [failed_event]
          )
        )

        code = run_cli(['deploy', '--format', 'json', '--yes'])
        expect(code).to eq(7)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('deploy')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(7)
        expect(json['diagnostics'].size).to eq(1)
        expect(json['diagnostics'].first['code']).to eq('VLT-CFN-ROLLBACK-LIMIT')
        expect(json['diagnostics'].first['suggested_action']).to include('Service Quotas')
        expect(json['diagnostics'].first['aws_resource_id']).to eq('WorkerFunction')
      end

      it 'returns structured JSON error with exit code 4 on verification failure with --format json' do
        account_error = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-ACCOUNT-001',
          severity: :error,
          summary: "AWS account mismatch: current '999999999999' != expected '123456789012'.",
          suggested_action: 'Switch credentials.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([account_error])

        code = run_cli(['deploy', '--format', 'json', '--yes'])
        expect(code).to eq(4)
        json = JSON.parse(stderr.string)
        expect(json['command']).to eq('deploy')
        expect(json['status']).to eq('error')
        expect(json['data']['error_code']).to eq(4)
        expect(json['data']['errors_count']).to eq(1)
        expect(json['diagnostics'].first['code']).to eq('VLT-AWS-ACCOUNT-001')
      end

      it 'returns structured JSON success with warning details when account is unconstrained with --format json' do
        warn_diag = Veltrunode::Diagnostics::Diagnostic.new(
          code: 'VLT-AWS-ACCOUNT-002',
          severity: :warning,
          summary: 'No account constraint specified.',
          suggested_action: 'Specify account constraint.'
        )
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([warn_diag])

        code = run_cli(['deploy', '--format', 'json', '--yes'])
        expect(code).to eq(0)
        json = JSON.parse(stdout.string)
        expect(json['command']).to eq('deploy')
        expect(json['status']).to eq('success')
        expect(json['data']['warnings_count']).to eq(1)
        expect(json['diagnostics'].first['code']).to eq('VLT-AWS-ACCOUNT-002')
        expect(json['data']['stack_name']).to eq('deploy-app-prod')
        expect(json['data']['events']).not_to be_empty
      end
    end

    it 'runs invoke local command' do
      mock_fn = Veltrunode::Model::Function.new(logical_name: 'my-func', handler: 'my_func.handler')
      mock_app = Veltrunode::Model::Application.new(name: 'test-app', functions: [mock_fn])
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)
      mock_result = Veltrunode::Runner::ExecutionResult.new(
        result: { 'message' => 'hello' },
        duration_ms: 12.34,
        memory_size_mb: 128,
        function_name: 'my-func'
      )
      allow(Veltrunode::Runner).to receive(:run).and_return(mock_result)

      code = run_cli(%w[invoke local my-func])
      expect(code).to eq(0)
      expect(stdout.string).to include('"message": "hello"')
    end

    describe 'destroy command' do
      let(:destroy_app_dev) do
        Veltrunode::Model::Application.new(
          name: 'destroy-app',
          region: 'ap-northeast-1',
          stage: 'dev',
          account_constraint: '123456789012'
        )
      end

      let(:destroy_app_prod) do
        Veltrunode::Model::Application.new(
          name: 'destroy-app',
          region: 'ap-northeast-1',
          stage: 'prod',
          account_constraint: '123456789012'
        )
      end

      let(:mock_resource) do
        Veltrunode::AWS::StackResource.new(
          logical_resource_id: 'MyFunction',
          physical_resource_id: 'arn:aws:lambda:ap-northeast-1:123456789012:function:destroy-app-dev-MyFunction',
          resource_type: 'AWS::Lambda::Function',
          resource_status: 'CREATE_COMPLETE'
        )
      end

      let(:mock_delete_event) do
        Veltrunode::AWS::StackEvent.new(
          event_id: 'ev-del-1',
          logical_resource_id: 'destroy-app-dev',
          resource_type: 'AWS::CloudFormation::Stack',
          resource_status: 'DELETE_COMPLETE',
          timestamp: Time.now
        )
      end

      let(:mock_destroyer) { instance_double(Veltrunode::AWS::StackDestroyer) }

      before do
        allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([])
        allow(Veltrunode::AWS::StackDestroyer).to receive(:new).and_return(mock_destroyer)
        allow(mock_destroyer).to receive(:stack_exists?).and_return(true)
        allow(mock_destroyer).to receive(:describe_stack_resources).and_return([mock_resource])
        allow(mock_destroyer).to receive(:delete_stack)
        allow(mock_destroyer).to receive(:wait_for_stack_deletion)
          .and_yield(mock_delete_event).and_return([mock_delete_event])
        allow($stdin).to receive(:tty?).and_return(false)
      end

      context '非保護ステージ（dev）' do
        before do
          allow(Veltrunode::SettingsLoader).to receive(:load).and_return(destroy_app_dev)
        end

        it '--yes オプションでスタックを削除しリソースプレビューと進捗を出力する' do
          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(0)
          expect(stdout.string).to include("Destroy plan for stack 'destroy-app-dev'")
          expect(stdout.string).to include('[DELETE] MyFunction [AWS::Lambda::Function]')
          expect(stdout.string).to include('[PROGRESS] destroy-app-dev [AWS::CloudFormation::Stack] DELETE_COMPLETE')
          expect(stdout.string).to include("Stack 'destroy-app-dev' has been successfully deleted.")
        end

        it 'TTY 非接続時に --yes なしで実行するとキャンセルされ exit_code 7 で終了する' do
          code = run_cli(['destroy'])
          expect(code).to eq(7)
          expect(stderr.string).to include('cancelled by user')
        end

        it 'TTY 接続時に y を入力すると削除が成功する' do
          allow($stdin).to receive(:tty?).and_return(true)
          allow($stdin).to receive(:gets).and_return("y\n")

          code = run_cli(['destroy'])
          expect(code).to eq(0)
          expect(stdout.string).to include("Stack 'destroy-app-dev' has been successfully deleted.")
        end

        it 'TTY 接続時に n を入力するとキャンセルされ exit_code 7 で終了する' do
          allow($stdin).to receive(:tty?).and_return(true)
          allow($stdin).to receive(:gets).and_return("n\n")

          code = run_cli(['destroy'])
          expect(code).to eq(7)
          expect(stderr.string).to include('cancelled by user')
        end

        it '--format json で成功時に JSON を出力する' do
          code = run_cli(['destroy', '--yes', '--format', 'json'])
          expect(code).to eq(0)

          json = JSON.parse(stdout.string)
          expect(json['command']).to eq('destroy')
          expect(json['status']).to eq('success')
          expect(json['data']['stack_name']).to eq('destroy-app-dev')
          expect(json['data']['resources']).to be_an(Array)
          expect(json['data']['events']).to be_an(Array)
          expect(json['data']['stack_not_found']).to be false
        end
      end

      context '保護ステージ（prod）' do
        before do
          allow(Veltrunode::SettingsLoader).to receive(:load).and_return(destroy_app_prod)
          allow(mock_destroyer).to receive(:stack_exists?).with('destroy-app-prod').and_return(true)
          allow(mock_destroyer).to receive(:describe_stack_resources)
            .with('destroy-app-prod').and_return([mock_resource])
          allow(mock_destroyer).to receive(:delete_stack).with('destroy-app-prod')
          allow(mock_destroyer).to receive(:wait_for_stack_deletion)
            .with('destroy-app-prod')
            .and_yield(mock_delete_event)
            .and_return([mock_delete_event])
        end

        it 'スタック名を正確に入力すると削除が成功する' do
          allow($stdin).to receive(:tty?).and_return(true)
          allow($stdin).to receive(:gets).and_return("destroy-app-prod\n")

          code = run_cli(['destroy'])
          expect(code).to eq(0)
          expect(stdout.string).to include("This is a protected stage ('prod')")
          expect(stdout.string).to include("Type the stack name 'destroy-app-prod' to confirm deletion")
          expect(stdout.string).to include("Stack 'destroy-app-prod' has been successfully deleted.")
        end

        it 'スタック名が一致しない場合はキャンセルされ exit_code 7 で終了する' do
          allow($stdin).to receive(:tty?).and_return(true)
          allow($stdin).to receive(:gets).and_return("wrong-stack-name\n")

          code = run_cli(['destroy'])
          expect(code).to eq(7)
          expect(stderr.string).to include('cancelled by user')
        end

        it 'TTY 非接続時は削除がキャンセルされ exit_code 7 で終了する' do
          code = run_cli(['destroy'])
          expect(code).to eq(7)
          expect(stderr.string).to include('cancelled by user')
        end

        it '--yes があっても保護ステージではスタック名の手入力を要求する' do
          allow($stdin).to receive(:tty?).and_return(true)
          allow($stdin).to receive(:gets).and_return("destroy-app-prod\n")

          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(0)
          expect(stdout.string).to include("This is a protected stage ('prod')")
        end
      end

      context 'スタックが存在しない場合' do
        before do
          allow(Veltrunode::SettingsLoader).to receive(:load).and_return(destroy_app_dev)
          allow(mock_destroyer).to receive(:stack_exists?).and_return(false)
        end

        it 'スタック不在のメッセージを出力して exit_code 0 で終了する' do
          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(0)
          expect(stdout.string).to include('does not exist')
        end

        it '--format json でスタック不在の場合に JSON を出力する' do
          code = run_cli(['destroy', '--yes', '--format', 'json'])
          expect(code).to eq(0)

          json = JSON.parse(stdout.string)
          expect(json['command']).to eq('destroy')
          expect(json['status']).to eq('success')
          expect(json['data']['stack_not_found']).to be true
        end
      end

      context 'AWS Guard 失敗' do
        before do
          allow(Veltrunode::SettingsLoader).to receive(:load).and_return(destroy_app_dev)
          account_error = Veltrunode::Diagnostics::Diagnostic.new(
            code: 'VLT-AWS-ACCOUNT-001',
            severity: :error,
            summary: 'AWS account mismatch.',
            suggested_action: 'Switch credentials.'
          )
          allow(Veltrunode::AWS::AccountRegionGuard).to receive(:check).and_return([account_error])
        end

        it 'AWS Guard エラー時に exit_code 4 で終了する' do
          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(4)
          expect(stderr.string).to include('AWS verification failed')
        end

        it '--format json で AWS Guard エラーを JSON 出力する' do
          code = run_cli(['destroy', '--yes', '--format', 'json'])
          expect(code).to eq(4)
          json = JSON.parse(stderr.string)
          expect(json['command']).to eq('destroy')
          expect(json['status']).to eq('error')
          expect(json['data']['error_code']).to eq(4)
        end
      end

      context '削除失敗' do
        before do
          allow(Veltrunode::SettingsLoader).to receive(:load).and_return(destroy_app_dev)
        end

        it 'delete_stack エラー時に exit_code 7 で終了する' do
          allow(mock_destroyer).to receive(:delete_stack)
            .and_raise(RuntimeError.new('Termination protection is enabled'))

          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(7)
          expect(stderr.string).to include('Failed to delete stack')
        end

        it 'wait_for_stack_deletion エラー時に exit_code 7 で終了する' do
          allow(mock_destroyer).to receive(:wait_for_stack_deletion)
            .and_raise(Veltrunode::AWS::StackDestroyError.new("deletion failed with status 'DELETE_FAILED'"))

          code = run_cli(['destroy', '--yes'])
          expect(code).to eq(7)
          expect(stderr.string).to include('Stack deletion failed')
        end
      end
    end

    it 'runs efs verify command stub' do
      code = run_cli(%w[efs verify my-efs])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('EFS verification successful for: my-efs.')
    end

    it 'runs layer inspect command stub' do
      code = run_cli(%w[layer inspect my-layer])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Inspected layer: my-layer.')
    end

    it 'runs schedule preview command stub' do
      code = run_cli(%w[schedule preview my-schedule])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Previewed schedule: my-schedule.')
    end
  end
end
