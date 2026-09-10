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
      expect(json['version']).to eq(Veltrunode::VERSION)
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
        expect(json['status']).to eq('success')
        expect(json['message']).to eq('Project initialized successfully.')
        expect(json['created_files']).to eq(%w[Veltrunodefile Gemfile .gitignore functions/app.rb])
        expect(json['skipped_files']).to eq([])
        expect(json['target_dir']).to eq('/path/to/app')
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
        expect(json['status']).to eq('success')
        expect(json['errors_count']).to eq(0)
        expect(json['warnings_count']).to eq(0)
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
        expect(json['status']).to eq('error')
        expect(json['error_code']).to eq(3)
        expect(json['errors_count']).to eq(1)
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
        expect(json['status']).to eq('error')
        expect(json['error_code']).to eq(8)
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
        expect(json['status']).to eq('success')
        expect(json['functions_count']).to eq(1)
        expect(json['layers_count']).to eq(1)
        expect(json['artifacts']['functions'].first['sha256']).to eq(
          '9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba'
        )
        expect(json['artifacts']['layers'].first['sha256']).to eq(
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
        )
        expect(json['template_path']).to end_with('template.yml')
        expect(json['manifest_path']).to end_with('manifest.json')
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
        expect(json['status']).to eq('error')
        expect(json['error_code']).to eq(3)
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
        expect(json['status']).to eq('error')
        expect(json['error_code']).to eq(5)
        expect(json['message']).to include('Build failed: Archive error')
      end
    end

    it 'runs plan command and outputs application plan and IAM capabilities' do
      mock_fn = Veltrunode::Model::Function.new(
        logical_name: 'api_fn',
        handler: 'api.handler',
        iam_capabilities: [{ type: :read_from_s3, params: { bucket: 'my-bucket' } }]
      )
      mock_app = Veltrunode::Model::Application.new(
        name: 'plan-app',
        functions: [mock_fn]
      )
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)

      code = run_cli(['plan'])
      expect(code).to eq(0)
      expect(stdout.string).to include("Plan generated for application 'plan-app'.")
      expect(stdout.string).to include('IAM Capabilities Expansion:')
      expect(stdout.string).to include("Function 'api_fn':")
      expect(stdout.string).to include('s3:GetObject, s3:ListBucket')
    end

    it 'runs plan command with --format json and outputs expanded IAM capabilities in JSON' do
      mock_fn = Veltrunode::Model::Function.new(
        logical_name: 'api_fn',
        handler: 'api.handler',
        iam_capabilities: [{ type: :read_from_s3, params: { bucket: 'my-bucket' } }]
      )
      mock_app = Veltrunode::Model::Application.new(
        name: 'plan-app',
        functions: [mock_fn]
      )
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(mock_app)

      code = run_cli(['plan', '--format', 'json'])
      expect(code).to eq(0)
      json = JSON.parse(stdout.string)
      expect(json['status']).to eq('success')
      expect(json['iam_capabilities']['api_fn']).to be_an(Array)
      expect(json['iam_capabilities']['api_fn'].first['Action']).to eq(%w[s3:GetObject s3:ListBucket])
    end

    it 'runs deploy command stub' do
      code = run_cli(['deploy'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Deployment successful.')
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

    it 'runs destroy command stub' do
      code = run_cli(['destroy'])
      expect(code).to eq(0)
      expect(stdout.string.strip).to eq('Stack destroyed.')
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
