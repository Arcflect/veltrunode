# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'tmpdir'
require 'veltrunode/aws/ecr_pusher'
require 'veltrunode/build/package_result'
require 'veltrunode/model/function'
require 'veltrunode/model/application'

RSpec.describe Veltrunode::AWS::EcrPusher do
  let(:ecr_client) { double('Aws::ECR::Client') }
  let(:encoded_token) { Base64.strict_encode64('AWS:secret-ecr-password') }
  let(:auth_data) do
    double(
      'AuthorizationData',
      authorization_token: encoded_token,
      proxy_endpoint: 'https://123456789012.dkr.ecr.ap-northeast-1.amazonaws.com'
    )
  end

  describe '#ensure_repository' do
    it 'returns existing repository URI when repository exists' do
      repo_obj = double(
        'Repository',
        repository_uri: '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference'
      )
      expect(ecr_client).to receive(:describe_repositories)
        .with(repository_names: ['ml_inference'])
        .and_return(double('DescribeRepositoriesResponse', repositories: [repo_obj]))

      pusher = described_class.new(ecr_client: ecr_client, region: 'ap-northeast-1', account_id: '123456789012')
      uri = pusher.ensure_repository('ml_inference')
      expect(uri).to eq('123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference')
    end

    it 'creates repository when RepositoryNotFoundException is raised' do
      not_found_err = StandardError.new('RepositoryNotFoundException: The repository does not exist in the registry')
      expect(ecr_client).to receive(:describe_repositories)
        .with(repository_names: ['ml_inference'])
        .and_raise(not_found_err)

      created_repo = double(
        'Repository',
        repository_uri: '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference'
      )
      expect(ecr_client).to receive(:create_repository).with(
        repository_name: 'ml_inference',
        image_scanning_configuration: { scan_on_push: true },
        encryption_configuration: { encryption_type: 'AES256' }
      ).and_return(double('CreateRepositoryResponse', repository: created_repo))

      pusher = described_class.new(ecr_client: ecr_client, region: 'ap-northeast-1', account_id: '123456789012')
      uri = pusher.ensure_repository('ml_inference')
      expect(uri).to eq('123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference')
    end
  end

  describe '#push_image and #push_and_update_template' do
    it 'authenticates with ECR, tags, pushes the image, and updates the CloudFormation template' do
      repo_obj = double(
        'Repository',
        repository_uri: '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference'
      )
      allow(ecr_client).to receive(:describe_repositories)
        .with(repository_names: ['ml_inference'])
        .and_return(double('DescribeRepositoriesResponse', repositories: [repo_obj]))
      allow(ecr_client).to receive(:get_authorization_token)
        .and_return(double('GetAuthorizationTokenResponse', authorization_data: [auth_data]))

      executed_commands = []
      runner = lambda do |cmd, stdin_data: nil|
        executed_commands << { cmd: cmd, stdin_data: stdin_data }
        stdout = if cmd[1] == 'push'
                   'v1.2.0: digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef size: 1234'
                 else
                   'Login Succeeded'
                 end
        [stdout, '', instance_double(Process::Status, success?: true, exitstatus: 0)]
      end

      fn = Veltrunode::Model::Function.new(
        logical_name: 'ml_inference',
        image: { dockerfile: './Dockerfile', tag: 'v1.2.0' }
      )
      app = Veltrunode::Model::Application.new(
        name: 'ml-app',
        region: 'ap-northeast-1',
        account_constraint: '123456789012',
        functions: [fn]
      )
      pkg_res = Veltrunode::Build::PackageResult.new(
        function_name: 'ml_inference',
        zip_path: '',
        sha256: 'abc123',
        bytesize: 100,
        entries: ['Dockerfile'],
        package_type: 'Image',
        image_uri: 'ml_inference:v1.2.0',
        image_tag: 'v1.2.0',
        dockerfile_path: '/app/Dockerfile'
      )

      template_data = {
        'Resources' => {
          'MlInferenceFunction' => {
            'Type' => 'AWS::Lambda::Function',
            'Properties' => {
              'FunctionName' => 'ml_inference',
              'PackageType' => 'Image',
              'Code' => {
                'ImageUri' => {
                  'Fn::Sub' => '${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/ml_inference:v1.2.0'
                }
              }
            }
          }
        }
      }

      build_result = double(
        'BuildResult',
        application: app,
        function_results: [pkg_res],
        template_path: nil,
        template_data: template_data
      )

      pusher = described_class.new(
        application: app,
        ecr_client: ecr_client,
        runner_executable: 'docker',
        command_runner: runner
      )

      outcome = pusher.push_and_update_template(build_result)
      push_results = outcome[:push_results]

      expect(push_results.size).to eq(1)
      res = push_results.first
      expect(res.pushed?).to be(true)
      expect(res.function_name).to eq('ml_inference')
      expect(res.repository_name).to eq('ml_inference')
      expect(res.image_uri).to eq('123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference:v1.2.0')
      expect(res.image_digest).to eq('sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')

      registry_host = '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com'
      remote_uri = "#{registry_host}/ml_inference:v1.2.0"
      expect(executed_commands.map { |c| c[:cmd] }).to eq(
        [
          ['docker', 'login', '--username', 'AWS', '--password-stdin', registry_host],
          ['docker', 'tag', 'ml_inference:v1.2.0', remote_uri],
          ['docker', 'push', remote_uri]
        ]
      )
      expect(executed_commands.first[:stdin_data]).to eq('secret-ecr-password')

      updated_code = outcome[:template]['Resources']['MlInferenceFunction']['Properties']['Code']
      expect(updated_code).to eq(
        'ImageUri' => '123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/ml_inference:v1.2.0'
      )
    end
  end
end
