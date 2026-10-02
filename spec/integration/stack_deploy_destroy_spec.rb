# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Stack deploy and destroy integration test', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/integration/minimal', __dir__) }
  let(:test_app_name) { IntegrationHelper.generate_app_name('min') }

  before do
    unless IntegrationHelper.aws_configured?
      skip 'AWS environment is not configured ' \
           '(check AWS_REGION, AWS_ACCOUNT_ID, VELTRUNODE_TEST_ARTIFACT_BUCKET)'
    end
  end

  it 'deploys minimal stack and destroys it with automated cleanup' do
    Dir.mktmpdir('veltrunode-deploy-destroy-test-') do |tmpdir|
      FileUtils.cp_r("#{fixture_dir}/.", tmpdir)

      # テスト専用の一意のアプリ名を設定
      ENV['VELTRUNODE_TEST_APP_NAME'] = test_app_name
      IntegrationHelper.register_stack(test_app_name)

      application = Veltrunode::SettingsLoader.load(file_path: File.join(tmpdir, 'Veltrunodefile'))

      begin
        # 1. デプロイ実行
        deploy_result = Veltrunode::Deploy::Pipeline.execute(
          application,
          source_dir: tmpdir,
          options: {
            'auto_approve' => true,
            'quiet' => false,
            'artifact_bucket' => ENV.fetch('VELTRUNODE_TEST_ARTIFACT_BUCKET', nil)
          }
        )

        expect(deploy_result.success?).to be true
        expect(deploy_result.stack_name).to eq(test_app_name)
      ensure
        # 2. 自動クリーンアップ（スタック削除）
        destroy_result = IntegrationHelper.cleanup_stack(application, source_dir: tmpdir)
        expect(destroy_result&.success?).to be true
      end
    end
  ensure
    ENV.delete('VELTRUNODE_TEST_APP_NAME')
  end
end
