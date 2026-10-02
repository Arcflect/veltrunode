# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'time'

RSpec.describe 'One-time schedule Lambda integration test', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/integration/one_time_schedule', __dir__) }
  let(:test_app_name) { IntegrationHelper.generate_app_name('sched') }

  before do
    unless IntegrationHelper.aws_configured?
      skip 'AWS environment is not configured ' \
           '(check AWS_REGION, AWS_ACCOUNT_ID, VELTRUNODE_TEST_ARTIFACT_BUCKET)'
    end
  end

  it 'deploys stack with at-expression schedule and verifies lambda execution' do
    Dir.mktmpdir('veltrunode-one-time-sched-test-') do |tmpdir|
      FileUtils.cp_r("#{fixture_dir}/.", tmpdir)

      # 3分後の未来時刻を設定
      future_time = (Time.now.utc + 180).strftime('%Y-%m-%dT%H:%M:%S')
      ENV['VELTRUNODE_TEST_APP_NAME'] = test_app_name
      ENV['VELTRUNODE_TEST_SCHEDULE_AT'] = future_time
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

        # デプロイされた Lambda 関数の直接呼び出しテスト
        function_name = "#{test_app_name}-ScheduledWorkerFunction"
        response = IntegrationHelper.invoke_lambda(function_name, { 'trigger' => 'test-runner' })

        expect(response[:status_code]).to eq(200)
        expect(response[:payload]['statusCode']).to eq(200)

        body = JSON.parse(response[:payload]['body'])
        expect(body['status']).to eq('ok')
        expect(body['message']).to eq('Triggered by one-time schedule')
      ensure
        # 自動クリーンアップ
        IntegrationHelper.cleanup_stack(application, source_dir: tmpdir)
      end
    end
  ensure
    ENV.delete('VELTRUNODE_TEST_APP_NAME')
    ENV.delete('VELTRUNODE_TEST_SCHEDULE_AT')
  end
end
