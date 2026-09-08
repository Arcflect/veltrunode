# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Veltrunode::Validation::Engine do
  let(:valid_layer) do
    Veltrunode::Model::Layer.new(
      name: 'valid-layer',
      compatible_runtimes: ['ruby3.3']
    )
  end

  let(:valid_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'valid_mount',
      access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-12345678',
      local_path: '/mnt/valid'
    )
  end

  let(:valid_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'valid_fn',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      layers: ['valid-layer'],
      mounts: ['valid_mount']
    )
  end

  let(:valid_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'valid_schedule',
      target_function: 'valid_fn',
      expression_type: :cron,
      expression: '0 0 * * ? *'
    )
  end

  let(:valid_app) do
    Veltrunode::Model::Application.new(
      name: 'valid-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      layers: [valid_layer],
      mounts: [valid_mount],
      functions: [valid_function],
      schedules: [valid_schedule]
    )
  end

  describe '.run' do
    it 'returns no error diagnostics for a completely valid Application' do
      diagnostics = described_class.run(valid_app)
      errors = diagnostics.select { |d| d.severity == :error }
      expect(errors).to be_empty
    end

    it 'detects invalid resource names (VLT-DSL-INVALID-NAME)' do
      invalid_name_app = Veltrunode::Model::Application.new(
        name: 'invalid app name!',
        region: 'ap-northeast-1',
        stage: 'dev'
      )

      diagnostics = described_class.run(invalid_name_app)
      name_error = diagnostics.find { |d| d.code == 'VLT-DSL-INVALID-NAME' }

      expect(name_error).not_to be_nil
      expect(name_error.severity).to eq(:error)
      expect(name_error.evidence['name']).to eq('invalid app name!')
    end

    it 'detects unresolved references via ResourceGraph (VLT-REF-001)' do
      invalid_ref_fn = Veltrunode::Model::Function.new(
        logical_name: 'ref_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        layers: ['non_existent_layer']
      )
      invalid_ref_app = Veltrunode::Model::Application.new(
        name: 'ref-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        functions: [invalid_ref_fn]
      )

      diagnostics = described_class.run(invalid_ref_app)
      ref_error = diagnostics.find { |d| d.code == 'VLT-REF-001' }

      expect(ref_error).not_to be_nil
      expect(ref_error.severity).to eq(:error)
    end

    it 'detects runtime incompatibility between Function and Layer (VLT-LAYER-001)' do
      python_layer = Veltrunode::Model::Layer.new(
        name: 'python-layer',
        compatible_runtimes: ['python3.11']
      )
      ruby_fn = Veltrunode::Model::Function.new(
        logical_name: 'ruby_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        layers: ['python-layer']
      )
      compat_app = Veltrunode::Model::Application.new(
        name: 'compat-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        layers: [python_layer],
        functions: [ruby_fn]
      )

      diagnostics = described_class.run(compat_app)
      compat_error = diagnostics.find { |d| d.code == 'VLT-LAYER-001' }

      expect(compat_error).not_to be_nil
      expect(compat_error.severity).to eq(:error)
    end

    it 'detects architecture incompatibility between Function and Layer (VLT-LAYER-001)' do
      arm_layer = Veltrunode::Model::Layer.new(
        name: 'arm-layer',
        compatible_runtimes: ['ruby3.3'],
        architectures: [:arm64]
      )
      x86_fn = Veltrunode::Model::Function.new(
        logical_name: 'x86_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        architecture: :x86_64,
        layers: ['arm-layer']
      )
      arch_app = Veltrunode::Model::Application.new(
        name: 'arch-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        layers: [arm_layer],
        functions: [x86_fn]
      )

      diagnostics = described_class.run(arch_app)
      arch_error = diagnostics.find { |d| d.code == 'VLT-LAYER-001' }

      expect(arch_error).not_to be_nil
      expect(arch_error.severity).to eq(:error)
    end

    it 'detects invalid EFS mount path format (VLT-EFS-PATH)' do
      valid_mount = Veltrunode::Model::EfsMount.new(
        symbolic_name: 'mount_one',
        access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-12345678',
        local_path: '/mnt/valid'
      )
      bad_path_fn = Veltrunode::Model::Function.new(
        logical_name: 'fn',
        handler: 'app.handler',
        mounts: ['mount_one:/invalid/path']
      )
      path_app = Veltrunode::Model::Application.new(
        name: 'path-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        mounts: [valid_mount],
        functions: [bad_path_fn]
      )

      diagnostics = described_class.run(path_app)
      path_error = diagnostics.find { |d| d.code == 'VLT-EFS-PATH' }

      expect(path_error).not_to be_nil
    end

    it 'detects IAM wildcard violations in prod stage' do
      cap = Veltrunode::Model::Capability.new(
        type: :custom,
        params: { actions: ['s3:GetObject'], resources: ['*'] }
      )
      wildcard_fn = Veltrunode::Model::Function.new(
        logical_name: 'wildcard_fn',
        handler: 'app.handler',
        iam_capabilities: [cap]
      )
      prod_app = Veltrunode::Model::Application.new(
        name: 'prod-app',
        region: 'ap-northeast-1',
        stage: 'prod',
        functions: [wildcard_fn]
      )

      diagnostics = described_class.run(prod_app)
      wildcard_error = diagnostics.find { |d| d.code == 'VLT-IAM-WILDCARD-RESOURCE' }

      expect(wildcard_error).not_to be_nil
      expect(wildcard_error.severity).to eq(:error)
    end

    it 'warns when prod stage lacks account_constraint' do
      prod_app = Veltrunode::Model::Application.new(
        name: 'prod-app',
        region: 'ap-northeast-1',
        stage: 'prod',
        functions: [valid_function]
      )

      diagnostics = described_class.run(prod_app)
      account_warn = diagnostics.find { |d| d.code == 'VLT-AWS-ACCOUNT-002' && d.severity == :warning }

      expect(account_warn).not_to be_nil
      expect(account_warn.summary).to include('does not have an explicit account_constraint configured')
    end

    it 'detects missing handler files in source_dir (VLT-BUILD-HANDLER-NOT-FOUND)' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
        handler_error = diagnostics.find { |d| d.code == 'VLT-BUILD-HANDLER-NOT-FOUND' }

        expect(handler_error).not_to be_nil
        expect(handler_error.severity).to eq(:error)
        expect(handler_error.evidence['function']).to eq('valid_fn')
      end
    end

    it 'passes packaging preconditions when handler file exists in source_dir' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        File.write(File.join(tmp_dir, 'app.rb'), 'def handler(event, context); end')

        diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
        handler_error = diagnostics.find { |d| d.code == 'VLT-BUILD-HANDLER-NOT-FOUND' }

        expect(handler_error).to be_nil
      end
    end

    it 'detects symlinks pointing outside source_dir (VLT-BUILD-SYMLINK-TRAVERSAL)' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        Dir.mktmpdir('veltrunode-test-outside-') do |outside_dir|
          File.write(File.join(tmp_dir, 'app.rb'), 'def handler(event, context); end')
          outside_file = File.join(outside_dir, 'secret.txt')
          File.write(outside_file, 'secret')
          File.symlink(outside_file, File.join(tmp_dir, 'leak.txt'))

          diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
          symlink_error = diagnostics.find { |d| d.code == 'VLT-BUILD-SYMLINK-TRAVERSAL' }

          expect(symlink_error).not_to be_nil
          expect(symlink_error.severity).to eq(:error)
        end
      end
    end

    it 'prunes well-known large/unpackaged directories like .git and node_modules from symlink scan' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        Dir.mktmpdir('veltrunode-test-outside-') do |outside_dir|
          File.write(File.join(tmp_dir, 'app.rb'), 'def handler(event, context); end')
          git_dir = File.join(tmp_dir, '.git')
          Dir.mkdir(git_dir)
          outside_file = File.join(outside_dir, 'git_hook_target')
          File.write(outside_file, 'hook')
          File.symlink(outside_file, File.join(git_dir, 'hook_symlink'))

          diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
          symlink_error = diagnostics.find { |d| d.code == 'VLT-BUILD-SYMLINK-TRAVERSAL' }

          expect(symlink_error).to be_nil
        end
      end
    end

    it 'detects sensitive files (.env, *.secret, credentials) during packaging validation' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        File.write(File.join(tmp_dir, 'app.rb'), 'def handler(event, context); end')
        File.write(File.join(tmp_dir, '.env'), 'SECRET_KEY=123')
        File.write(File.join(tmp_dir, 'app.secret'), 'mysecret')

        diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
        secret_warns = diagnostics.select { |d| d.code == 'VLT-BUILD-SECRET-WARN' }

        expect(secret_warns.size).to eq(2)
        expect(secret_warns.map(&:severity)).to all(eq(:warning))
        expect(secret_warns.map { |d| d.evidence['file'] }).to contain_exactly('.env', 'app.secret')
      end
    end

    it 'detects high-entropy strings during packaging validation' do
      Dir.mktmpdir('veltrunode-test-source-') do |tmp_dir|
        File.write(File.join(tmp_dir, 'app.rb'), <<~RUBY)
          API_KEY = "d8F9ax83Lq4b72MzA1p9V0kLmNoPqRsT"
          def handler(event, context); end
        RUBY

        diagnostics = described_class.run(valid_app, source_dir: tmp_dir)
        secret_warn = diagnostics.find { |d| d.code == 'VLT-BUILD-SECRET-WARN' }

        expect(secret_warn).not_to be_nil
        expect(secret_warn.severity).to eq(:warning)
        expect(secret_warn.evidence['reason']).to eq('high entropy string detected')
      end
    end

    describe 'StagePolicy validation' do
      it 'detects wildcard IAM actions when deny_wildcard_actions is enabled (VLT-IAM-001)' do
        cap = Veltrunode::Model::Capability.new(
          type: :custom,
          params: { actions: ['s3:*'], resources: ['arn:aws:s3:::my-bucket/*'] }
        )
        fn = Veltrunode::Model::Function.new(
          logical_name: 'wildcard_fn',
          handler: 'app.handler',
          iam_capabilities: [cap]
        )
        policy = Veltrunode::Model::StagePolicy.new(
          :staging,
          deny_wildcard_actions: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'policy-app',
          stage: 'staging',
          policies: [policy],
          functions: [fn]
        )

        diagnostics = described_class.run(app)
        iam_error = diagnostics.find { |d| d.code == 'VLT-IAM-001' }

        expect(iam_error).not_to be_nil
        expect(iam_error.severity).to eq(:error)
        expect(iam_error.evidence['policy_violation']).to be(true)
      end

      it 'detects wildcard IAM actions in production when deny_wildcard_actions is enabled (VLT-IAM-001)' do
        cap = Veltrunode::Model::Capability.new(
          type: :custom,
          params: { actions: ['s3:*'], resources: ['arn:aws:s3:::my-bucket/*'] }
        )
        fn = Veltrunode::Model::Function.new(
          logical_name: 'prod_wildcard_fn',
          handler: 'app.handler',
          iam_capabilities: [cap]
        )
        policy = Veltrunode::Model::StagePolicy.new(
          :production,
          deny_wildcard_actions: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'policy-app',
          stage: 'production',
          account_constraint: '123456789012',
          policies: [policy],
          functions: [fn]
        )

        diagnostics = described_class.run(app)
        iam_error = diagnostics.find { |d| d.code == 'VLT-IAM-001' && d.evidence['policy_violation'] }

        expect(iam_error).not_to be_nil
        expect(iam_error.severity).to eq(:error)
        expect(iam_error.evidence['policy_violation']).to be(true)
        expect(iam_error.evidence['stage']).to eq('production')
      end

      it 'detects missing DLQ when require_dlq is enabled (VLT-SCHED-001)' do
        sched = Veltrunode::Model::Schedule.new(
          name: 'nightly',
          target_function: 'my_fn',
          expression_type: :cron,
          expression: '0 0 * * ? *'
        )
        policy = Veltrunode::Model::StagePolicy.new(
          :production,
          require_dlq: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'dlq-policy-app',
          stage: 'production',
          policies: [policy],
          schedules: [sched]
        )

        diagnostics = described_class.run(app)
        sched_error = diagnostics.find { |d| d.code == 'VLT-SCHED-001' }

        expect(sched_error).not_to be_nil
        expect(sched_error.severity).to eq(:error)
        expect(sched_error.evidence['policy_violation']).to be(true)
      end

      it 'detects missing log retention when require_log_retention is enabled (VLT-BUILD-001)' do
        policy = Veltrunode::Model::StagePolicy.new(
          :production,
          require_log_retention: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'logs-policy-app',
          stage: 'production',
          policies: [policy],
          functions: [valid_function]
        )

        diagnostics = described_class.run(app)
        log_error = diagnostics.find { |d| d.code == 'VLT-BUILD-001' }

        expect(log_error).not_to be_nil
        expect(log_error.severity).to eq(:error)
        expect(log_error.evidence['policy_violation']).to be(true)
      end

      it 'passes log retention check when runtime_defaults has retention_days' do
        policy = Veltrunode::Model::StagePolicy.new(
          :production,
          require_log_retention: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'logs-policy-app',
          stage: 'production',
          runtime_defaults: { logs: { retention_days: 14 } },
          policies: [policy],
          functions: [valid_function]
        )

        diagnostics = described_class.run(app)
        log_error = diagnostics.find { |d| d.code == 'VLT-BUILD-001' }

        expect(log_error).to be_nil
      end

      it 'detects public storage usage when deny_public_storage is enabled (VLT-IAM-001)' do
        cap = Veltrunode::Model::Capability.new(
          type: :write_to_s3,
          params: { bucket: 'my-bucket', public: true }
        )
        fn = Veltrunode::Model::Function.new(
          logical_name: 'public_storage_fn',
          handler: 'app.handler',
          iam_capabilities: [cap]
        )
        policy = Veltrunode::Model::StagePolicy.new(
          :production,
          deny_public_storage: true
        )
        app = Veltrunode::Model::Application.new(
          name: 'storage-policy-app',
          stage: 'production',
          policies: [policy],
          functions: [fn]
        )

        diagnostics = described_class.run(app)
        storage_error = diagnostics.find { |d| d.code == 'VLT-IAM-001' && d.evidence['policy_violation'] }

        expect(storage_error).not_to be_nil
        expect(storage_error.severity).to eq(:error)
      end
    end

    it 'deduplicates identical diagnostics produced across validation phases' do
      invalid_ref_fn = Veltrunode::Model::Function.new(
        logical_name: 'ref_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        layers: ['missing_layer']
      )
      invalid_ref_app = Veltrunode::Model::Application.new(
        name: 'ref-app',
        region: 'ap-northeast-1',
        stage: 'dev',
        functions: [invalid_ref_fn]
      )

      diagnostics = described_class.run(invalid_ref_app)
      ref_errors = diagnostics.select { |d| d.code == 'VLT-REF-001' && d.evidence['missing_layer'] == 'missing_layer' }

      expect(ref_errors.size).to eq(1)
    end
  end

  describe '.run!' do
    it 'raises ValidationError when errors are detected' do
      invalid_app = Veltrunode::Model::Application.new(
        name: 'invalid app!',
        region: 'ap-northeast-1',
        stage: 'dev'
      )

      expect { described_class.run!(invalid_app) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
        }
    end

    it 'does not raise error when application is valid' do
      expect { described_class.run!(valid_app) }.not_to raise_error
    end
  end
end
