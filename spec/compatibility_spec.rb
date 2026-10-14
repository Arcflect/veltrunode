# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Compatibility Matrix' do
  let(:supported_runtimes) { %w[ruby3.2 ruby3.3 ruby3.4] }
  let(:supported_architectures) { %i[x86_64 arm64] }

  describe 'LayerPackager ABI resolution' do
    it 'maps all supported Lambda Ruby runtimes to their expected ABI versions' do
      expected_abis = {
        'ruby3.2' => '3.2.0',
        'ruby3.3' => '3.3.0',
        'ruby3.4' => '3.4.0'
      }

      expected_abis.each do |runtime, expected_abi|
        expect(Veltrunode::Build::LayerPackager::RUNTIME_ABI_MAP[runtime]).to eq(expected_abi)
      end
    end

    it 'packages gems into corresponding ABI directory for ruby3.4' do
      Dir.mktmpdir do |tmpdir|
        lockfile_path = File.join(tmpdir, 'Gemfile.lock')
        File.write(lockfile_path, <<~LOCKFILE)
          GEM
            remote: https://rubygems.org/
            specs:
              json (2.7.1)
          PLATFORMS
            ruby
          DEPENDENCIES
            json
          RUBY VERSION
             ruby 3.4.0p0
          BUNDLED WITH
             2.5.6
        LOCKFILE

        layer = Veltrunode::Model::Layer.new(
          name: 'ruby34-layer',
          compatible_runtimes: ['ruby3.4'],
          architectures: [:arm64]
        )

        output_dir = File.join(tmpdir, 'build', 'artifacts', 'layers')
        result = Veltrunode::Build::LayerPackager.package(
          layer: layer,
          gemfile_lock_path: lockfile_path,
          source_dir: tmpdir,
          output_dir: output_dir,
          allow_missing_gems: true
        )

        expect(result.entries).to include('ruby/gems/3.4.0/specifications/json-2.7.1.gemspec')
      end
    end
  end

  describe 'Compilation compatibility across runtimes and architectures' do
    supported_runtimes_map = {
      'ruby3.2' => '3.2',
      'ruby3.3' => '3.3',
      'ruby3.4' => '3.4'
    }

    supported_runtimes_map.each do |lambda_runtime, dsl_version|
      %i[x86_64 arm64].each do |arch|
        it "successfully compiles CloudFormation template for #{lambda_runtime} with #{arch}" do
          app = Veltrunode::DSL.evaluate "matrix-app-#{lambda_runtime.tr('.', '-')}-#{arch}" do
            aws region: 'ap-northeast-1', account: '123456789012'
            runtime ruby: dsl_version, architecture: arch

            function :handler do
              handler 'app.handler'
              timeout 30
              memory 256
            end
          end

          template = Veltrunode::Compiler::CloudFormation::TemplateCompiler.compile(app)

          cfn_func = template.dig('Resources', 'HandlerFunction', 'Properties')
          expect(cfn_func).not_to be_nil
          expect(cfn_func['Runtime']).to eq(lambda_runtime)
          expect(cfn_func['Architectures']).to eq([arch.to_s])
        end
      end
    end
  end

  describe 'Target environment evaluation from CI matrix' do
    let(:ci_lambda_runtime) { ENV.fetch('VELTRUNODE_TEST_LAMBDA_RUNTIME', nil) }
    let(:ci_arch) { ENV.fetch('VELTRUNODE_TEST_ARCH', nil) }

    it 'validates specified CI matrix target if set' do
      skip 'CI matrix environment variables not set' unless ci_lambda_runtime

      expect(supported_runtimes).to include(ci_lambda_runtime)

      if ci_arch
        expect(%w[x86_64 arm64]).to include(ci_arch)
      end

      # Validate building an app with the exact CI target configuration
      version_str = ci_lambda_runtime.sub(/^ruby/, '')
      target_arch = ci_arch ? ci_arch.to_sym : :x86_64

      app = Veltrunode::DSL.evaluate 'ci-matrix-app' do
        aws region: 'ap-northeast-1', account: '123456789012'
        runtime ruby: version_str, architecture: target_arch

        function :worker do
          handler 'worker.process'
        end
      end

      template = Veltrunode::Compiler::CloudFormation::TemplateCompiler.compile(app)

      func = template.dig('Resources', 'WorkerFunction', 'Properties')
      expect(func['Runtime']).to eq(ci_lambda_runtime)
      expect(func['Architectures']).to eq([target_arch.to_s])
    end
  end
end
