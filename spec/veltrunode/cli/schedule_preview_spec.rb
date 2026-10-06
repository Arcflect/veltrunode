# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'json'
require 'veltrunode/cli'
require 'veltrunode/model'
require 'veltrunode/scheduler'

RSpec.describe 'CLI veltrunode schedule preview NAME' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  let(:cron_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'cleanup-cron',
      target_function: 'cleaner',
      expression_type: :cron,
      expression: 'cron(30 2 * * ? *)',
      timezone: 'America/New_York'
    )
  end

  let(:tokyo_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'tokyo-cron',
      target_function: 'reporter',
      expression_type: :cron,
      expression: 'cron(0 9 ? * MON-FRI *)',
      timezone: 'Asia/Tokyo'
    )
  end

  let(:rate_schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'batch-rate',
      target_function: 'worker',
      expression_type: :rate,
      expression: 'rate(10 minutes)',
      timezone: 'UTC'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'scheduler-test-app',
      region: 'us-east-1',
      stage: 'dev',
      schedules: [cron_schedule, tokyo_schedule, rate_schedule]
    )
  end

  before do
    allow($stdout).to receive(:puts) { |val| stdout.puts(val) }
    allow($stdout).to receive(:print) { |val| stdout.print(val) }
    allow($stderr).to receive(:puts) { |val| stderr.puts(val) }
    allow(Veltrunode::SettingsLoader).to receive(:load).and_return(application)
  end

  def run_cli(args)
    stdout.string.clear
    stderr.string.clear
    Veltrunode::CLI::Router.run(args)
  end

  describe 'テキスト出力モード（デフォルト）' do
    it 'デフォルトで10回分の実行予定日時と免責事項を出力し、終了コード0を返すこと' do
      code = run_cli(%w[schedule preview tokyo-cron])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Veltrunode Schedule Preview')
      expect(output).to include('Schedule:         tokyo-cron')
      expect(output).to include('Target Function:  reporter')
      expect(output).to include('Expression:       cron(0 9 ? * MON-FRI *) (cron)')
      expect(output).to include('Timezone:         Asia/Tokyo')
      expect(output).to include('Count:            10')
      expect(output).to include('Upcoming Occurrences:')
      expect(output).to include('#1')
      expect(output).to include('#10')
      expect(output).to include('JST')
      expect(output).to include('DST Transitions:')
      expect(output).to include('None in this preview window.')
      expect(output).to include('Note: This preview is an estimate for reference only.')
    end

    it '--count 5 で指定した回数分のみ計算して出力すること' do
      code = run_cli(%w[schedule preview tokyo-cron --count 5])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Count:            5')
      expect(output).to include('#5')
      expect(output).not_to include('#6')
    end

    it '--count=3 形式のオプション指定にも対応すること' do
      code = run_cli(%w[schedule preview tokyo-cron --count=3])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Count:            3')
      expect(output).to include('#3')
      expect(output).not_to include('#4')
    end

    it 'rate式のスケジュールに対しても正常に将来の実行予定を出力すること' do
      code = run_cli(%w[schedule preview batch-rate --count 4])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('Schedule:         batch-rate')
      expect(output).to include('Expression:       rate(10 minutes) (rate)')
      expect(output).to include('Count:            4')
      expect(output).to include('#4')
    end

    it 'DST（夏時間）遷移がある場合に影響を明示表示すること' do
      # 2026-03-08 Spring Forward: America/New_York (EST -> EDT)
      fake_now = Time.utc(2026, 3, 6, 0, 0, 0)
      allow(Time).to receive(:now).and_return(fake_now)

      code = run_cli(%w[schedule preview cleanup-cron --count 4])

      expect(code).to eq(0)
      output = stdout.string
      expect(output).to include('[DST Transition] EST -> EDT')
      expect(output).to include('Notice: Scheduled hour was skipped due to DST spring forward')
      expect(output).to include('Daylight Saving Time begins: clocks advanced from EST (-05:00) to EDT (-04:00).')
    end
  end

  describe 'JSON出力モード (--format json)' do
    it '共通スキーマに準拠したJSONを出力し、dataに実行予定一覧が含まれること' do
      code = run_cli(%w[schedule preview tokyo-cron --count 5 --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)

      expect(parsed['command']).to eq('schedule preview')
      expect(parsed['status']).to eq('success')
      expect(parsed['diagnostics']).to be_empty

      data = parsed['data']
      expect(data['schedule_name']).to eq('tokyo-cron')
      expect(data['target_function']).to eq('reporter')
      expect(data['expression']).to eq('cron(0 9 ? * MON-FRI *)')
      expect(data['expression_type']).to eq('cron')
      expect(data['timezone']).to eq('Asia/Tokyo')
      expect(data['count']).to eq(5)
      expect(data['disclaimer']).to include('estimate for reference only')

      occurrences = data['occurrences']
      expect(occurrences.size).to eq(5)
      first = occurrences.first
      expect(first['sequence']).to eq(1)
      expect(first['timezone']).to eq('Asia/Tokyo')
      expect(first['timezone_abbr']).to eq('JST')
      expect(first['utc_offset']).to eq('+09:00')
      expect(first['dst']).to be(false)
      expect(first['local_time']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00\z/)
      expect(first['utc_time']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'DST遷移がある場合にJSON内のdst_transitionsおよび該当occurrenceに遷移情報を含むこと' do
      fake_now = Time.utc(2026, 3, 6, 0, 0, 0)
      allow(Time).to receive(:now).and_return(fake_now)

      code = run_cli(%w[schedule preview cleanup-cron --count 4 --format json])

      expect(code).to eq(0)
      parsed = JSON.parse(stdout.string.strip)
      data = parsed['data']

      transitions = data['dst_transitions']
      expect(transitions.size).to eq(1)
      expect(transitions.first['type']).to eq('spring_forward')
      expect(transitions.first['from_timezone_abbr']).to eq('EST')
      expect(transitions.first['to_timezone_abbr']).to eq('EDT')

      occ3 = data['occurrences'][2]
      expect(occ3['dst']).to be(true)
      expect(occ3['dst_transition']).not_to be_nil
      expect(occ3['shift_notice']).to include('skipped due to DST spring forward')
    end
  end

  describe 'エラーハンドリング' do
    it 'スケジュール名が未指定の場合に終了コード2を返すこと' do
      code = run_cli(%w[schedule preview])

      expect(code).to eq(2)
      expect(stderr.string).to include('Schedule name is required for schedule preview.')
    end

    it '存在しないスケジュール名が指定された場合に終了コード2を返すこと' do
      code = run_cli(%w[schedule preview non-existent-schedule])

      expect(code).to eq(2)
      expect(stderr.string).to include("Schedule 'non-existent-schedule' not found")
    end

    it '無効な count が指定された場合に終了コード2を返すこと' do
      code = run_cli(%w[schedule preview tokyo-cron --count 0])

      expect(code).to eq(2)
      expect(stderr.string).to include("Invalid count '0'. Count must be a positive integer.")

      code2 = run_cli(%w[schedule preview tokyo-cron --count invalid])
      expect(code2).to eq(2)
      expect(stderr.string).to include("Invalid count 'invalid'. Count must be a positive integer.")
    end

    it '無効なスケジュール式の場合に終了コード3を返すこと' do
      broken_schedule = Veltrunode::Model::Schedule.allocate
      broken_schedule.instance_variable_set(:@name, 'broken')
      broken_schedule.instance_variable_set(:@expression, 'cron(invalid format)')
      broken_schedule.instance_variable_set(:@timezone, 'UTC')
      broken_schedule.instance_variable_set(:@expression_type, :cron)

      app = Veltrunode::Model::Application.new(
        name: 'broken-app',
        region: 'us-east-1',
        stage: 'dev',
        schedules: [broken_schedule]
      )
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

      code = run_cli(%w[schedule preview broken])
      expect(code).to eq(3)
      expect(stderr.string).to include('Cron expression must contain exactly 6 fields')
    end
  end
end
