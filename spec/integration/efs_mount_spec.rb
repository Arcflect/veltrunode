# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'EFS mount and file I/O integration test', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/integration/with_efs', __dir__) }
  let(:test_app_name) { IntegrationHelper.generate_app_name('efs') }

  before do
    unless IntegrationHelper.efs_configured?
      skip 'EFS test environment is not configured ' \
           '(check VELTRUNODE_TEST_EFS_ACCESS_POINT, VELTRUNODE_TEST_SUBNET_IDS, VELTRUNODE_TEST_SECURITY_GROUP_IDS)'
    end
  end

  it 'mounts EFS access point and performs file write and read from lambda' do
    Dir.mktmpdir('veltrunode-efs-mount-test-') do |tmpdir|
      FileUtils.cp_r("#{fixture_dir}/.", tmpdir)

      ENV['VELTRUNODE_TEST_APP_NAME'] = test_app_name
      IntegrationHelper.register_stack(test_app_name)

      application = Veltrunode::SettingsLoader.load(file_path: File.join(tmpdir, 'Veltrunodefile'))

      begin
        # デプロイ
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

        # Lambda 呼び出しで EFS 読み書きを検証
        function_name = "#{test_app_name}-EfsWorkerFunction"
        test_content = "Integration test message at #{Time.now.to_i}"
        response = IntegrationHelper.invoke_lambda(function_name, { 'content' => test_content })

        expect(response[:status_code]).to eq(200)
        expect(response[:payload]['statusCode']).to eq(200)

        body = JSON.parse(response[:payload]['body'])
        expect(body['written']).to eq(test_content)
        expect(body['read']).to eq(test_content)
        expect(body['matched']).to be true
      ensure
        # 自動クリーンアップ
        IntegrationHelper.cleanup_stack(application, source_dir: tmpdir)
      end
    end
  ensure
    ENV.delete('VELTRUNODE_TEST_APP_NAME')
  end
end
