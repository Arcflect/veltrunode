# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::DSL do
  before do
    Veltrunode.reset!
  end

  let(:sample_veltrunodefile_content) do
    <<~RUBY
      Veltrunode.application "document-converter" do
        aws region: "ap-northeast-1", account: "123456789012"
        runtime ruby: "3.4", architecture: :arm64

        defaults do
          logs retention_days: 30
          tags system: "document-converter", managed_by: "veltrunode"
        end

        layer :runtime_gems do
          bundle lockfile: "Gemfile.lock", without: %i[development test]
          include_gems %w[aws-sdk-s3 nokogiri]
          build_on :amazon_linux_2023
          retain latest: 5
        end

        efs_mount :workspace do
          existing_access_point arn: "arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0"
          local_path "/mnt/workspace"
          expect_posix uid: 1000, gid: 1000
        end

        function :convert do
          handler "functions/convert.handler"
          memory 4096
          timeout 900
          ephemeral_storage 4096
          attach_layer :runtime_gems
          mount :workspace
          permit do
            read_from_s3 bucket: ref(:input_bucket)
            write_to_s3 bucket: ref(:output_bucket)
          end
        end

        schedule :nightly do
          target :convert
          cron "0 1 * * ? *", timezone: "Asia/Tokyo"
          input source: "nightly"
          retry maximum_attempts: 2, maximum_event_age: 7200
          dead_letter_queue arn: "arn:aws:sqs:ap-northeast-1:123456789012:dlq"
        end
      end
    RUBY
  end

  describe '.parse' do
    it 'parses sample Veltrunodefile code and creates a typed Application model' do
      app = Veltrunode.parse(sample_veltrunodefile_content)

      expect(app).to be_a(Veltrunode::Model::Application)
      expect(app.name).to eq('document-converter')
      expect(app.region).to eq('ap-northeast-1')
      expect(app.account_constraint).to eq('123456789012')
      expect(app.tags).to eq({ system: 'document-converter', managed_by: 'veltrunode' })

      # Layer validation
      expect(app.layers.size).to eq(1)
      layer = app.layers.first
      expect(layer.name).to eq('runtime_gems')
      expect(layer.build_environment['lockfile']).to eq('Gemfile.lock')
      expect(layer.build_environment['without']).to eq(%w[development test])
      expect(layer.build_environment['include_gems']).to eq(%w[aws-sdk-s3 nokogiri])
      expect(layer.retention_policy).to eq({ latest: 5 })

      # EfsMount validation
      expect(app.mounts.size).to eq(1)
      mount = app.mounts.first
      expect(mount.symbolic_name).to eq('workspace')
      expect(mount.local_path).to eq('/mnt/workspace')
      expect(mount.posix_expectations).to eq({ 'uid' => 1000, 'gid' => 1000 })

      # Function validation
      expect(app.functions.size).to eq(1)
      fn = app.functions.first
      expect(fn.logical_name).to eq('convert')
      expect(fn.handler).to eq('functions/convert.handler')
      expect(fn.memory).to eq(4096)
      expect(fn.timeout).to eq(900)
      expect(fn.ephemeral_storage).to eq(4096)
      expect(fn.layers).to eq(['runtime_gems'])
      expect(fn.mounts).to eq(['workspace'])
      expect(fn.iam_capabilities.size).to eq(2)
      expect(fn.iam_capabilities.map(&:type)).to eq(%i[read_from_s3 write_to_s3])

      # Schedule validation
      expect(app.schedules.size).to eq(1)
      sched = app.schedules.first
      expect(sched.name).to eq('nightly')
      expect(sched.target_function).to eq('convert')
      expect(sched.expression_type).to eq(:cron)
      expect(sched.expression).to eq('0 1 * * ? *')
      expect(sched.timezone).to eq('Asia/Tokyo')
      expect(sched.retry_policy['maximum_attempts']).to eq(2)
      expect(sched.dlq).to eq('arn:aws:sqs:ap-northeast-1:123456789012:dlq')
    end
  end

  describe 'stage_policy DSL' do
    it 'supports keyword argument definition for stage policies' do
      code = <<~RUBY
        Veltrunode.application "policy-app" do
          stage_policy :production,
                       deny_wildcard_actions: true,
                       require_dlq: true,
                       require_log_retention: true,
                       deny_public_storage: true
        end
      RUBY

      app = Veltrunode.parse(code)
      expect(app.policies.size).to eq(1)
      policy = app.policies.first
      expect(policy.stage).to eq('production')
      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(true)
      expect(policy.deny_public_storage?).to be(true)
    end

    it 'supports block definition for stage policies' do
      code = <<~RUBY
        Veltrunode.application "block-policy-app" do
          policy "staging" do
            deny_wildcard_actions true
            require_dlq true
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      expect(app.policies.size).to eq(1)
      policy = app.policies.first
      expect(policy.stage).to eq('staging')
      expect(policy.deny_wildcard_actions?).to be(true)
      expect(policy.require_dlq?).to be(true)
      expect(policy.require_log_retention?).to be(false)
      expect(policy.deny_public_storage?).to be(false)
    end
  end

  describe 'undefined method handling' do
    it 'raises ValidationError with VLT-DSL-001 diagnostic when an undefined method is called' do
      invalid_code = <<~RUBY
        Veltrunode.application "invalid-app" do
          aws region: "ap-northeast-1"
          unknown_dsl_method "some_value"
        end
      RUBY

      expect { Veltrunode.parse(invalid_code) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-DSL-001')
        }
    end
  end

  describe 'env and SecretValue helpers' do
    before do
      ENV['TEST_ENV_VAR'] = 'my_secret_token'
    end

    after do
      ENV.delete('TEST_ENV_VAR')
    end

    it 'reads environment variables and masks secrets in inspect' do
      code = <<~RUBY
        Veltrunode.application "env-app" do
          aws region: "ap-northeast-1"
          function :test_fn do
            handler "fn.handler"
            environment SECRET: env("TEST_ENV_VAR", secret: true)
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      fn = app.functions.first
      secret_val = fn.environment['SECRET']

      expect(secret_val).to be_a(Veltrunode::DSL::SecretValue)
      expect(secret_val.to_s).to eq('my_secret_token')
      expect(secret_val.inspect).to eq('[FILTERED]')
    end

    it 'supports Python runtime DSL at application and function level' do
      code = <<~RUBY
        Veltrunode.application "python-app" do
          aws region: "ap-northeast-1"
          runtime python: "3.12", architecture: :x86_64

          layer :py_deps do
            pip requirements: "requirements.txt"
            compatible_runtimes ["python3.12"]
          end

          function :default_py_fn do
            handler "app.handler"
          end

          function :explicit_py_fn do
            handler "worker.handler"
            runtime python: "3.11"
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      expect(app.runtime).to eq('python3.12')
      expect(app.runtime_defaults[:python]).to eq('3.12')

      layer = app.layers.first
      expect(layer.name).to eq('py_deps')
      expect(layer.build_environment['requirements']).to eq('requirements.txt')
      expect(layer.compatible_runtimes).to eq(['python3.12'])

      fn1 = app.functions.find { |f| f.logical_name == 'default_py_fn' }
      expect(fn1.runtime).to eq('python3.12')

      fn2 = app.functions.find { |f| f.logical_name == 'explicit_py_fn' }
      expect(fn2.runtime).to eq('python3.11')
    end

    it 'supports Node.js runtime DSL at application and function level' do
      code = <<~RUBY
        Veltrunode.application "node-app" do
          aws region: "ap-northeast-1"
          runtime nodejs: "20.x", architecture: :arm64

          layer :node_deps do
            npm package_json: "package.json"
            compatible_runtimes ["nodejs20.x"]
          end

          function :default_node_fn do
            handler "index.handler"
          end

          function :explicit_node_fn do
            handler "server.handler"
            runtime nodejs: "18.x"
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      expect(app.runtime).to eq('nodejs20.x')
      expect(app.runtime_defaults[:nodejs]).to eq('20.x')

      layer = app.layers.first
      expect(layer.name).to eq('node_deps')
      expect(layer.build_environment['package_json']).to eq('package.json')
      expect(layer.compatible_runtimes).to eq(['nodejs20.x'])

      fn1 = app.functions.find { |f| f.logical_name == 'default_node_fn' }
      expect(fn1.runtime).to eq('nodejs20.x')

      fn2 = app.functions.find { |f| f.logical_name == 'explicit_node_fn' }
      expect(fn2.runtime).to eq('nodejs18.x')
    end
  end

  describe 'ref helper' do
    it 'creates a Reference object' do
      ref_obj = Veltrunode::DSL::Reference.new(:input_bucket)
      expect(ref_obj.name).to eq(:input_bucket)
      expect(ref_obj.inspect).to eq('ref(:input_bucket)')
    end
  end

  describe 'runtime normalization' do
    it 'normalizes node runtime when node prefix is provided in DSL' do
      code = <<~RUBY
        Veltrunode.application "node-prefix-app" do
          aws region: "ap-northeast-1"
          runtime node: "node20.x"

          function :handler_fn1 do
            handler "index.handler"
            runtime node: "node18.x"
          end

          function :handler_fn2 do
            handler "index.handler"
            runtime nodejs: "node18.x"
          end

          function :handler_fn3 do
            handler "index.handler"
            runtime "node18.x"
          end
        end
      RUBY

      app = Veltrunode.parse(code)
      expect(app.runtime).to eq('nodejs20.x')
      expect(app.functions.find { |f| f.logical_name == 'handler_fn1' }.runtime).to eq('nodejs18.x')
      expect(app.functions.find { |f| f.logical_name == 'handler_fn2' }.runtime).to eq('nodejs18.x')
      expect(app.functions.find { |f| f.logical_name == 'handler_fn3' }.runtime).to eq('nodejs18.x')
    end
  end
end
