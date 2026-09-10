# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'stringio'

RSpec.describe 'veltrunode invoke local CLI' do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def run_cli(argv)
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = stdout
    $stderr = stderr

    Veltrunode::CLI::Router.run(argv)
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  describe 'invoke local command execution' do
    it 'executes function locally with text output by default' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'handler.rb'), <<~RUBY)
          def process(event:, context:)
            { status: 'ok', msg: 'Hello local' }
          end
        RUBY

        fn = Veltrunode::Model::Function.new(:my_func, handler: 'handler.process')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(%w[invoke local my_func])
          expect(code).to eq(0)
          expect(stdout.string).to include('"status": "ok"')
          expect(stdout.string).to include('"msg": "Hello local"')
        end
      end
    end

    it 'executes function locally with JSON output when --format json is specified' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'handler.rb'), <<~RUBY)
          def process(event:, context:)
            { count: 100 }
          end
        RUBY

        fn = Veltrunode::Model::Function.new(:json_fn, handler: 'handler.process')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(%w[invoke local json_fn --format json])
          expect(code).to eq(0)
          json = JSON.parse(stdout.string)
          expect(json['status']).to eq('success')
          expect(json['function_name']).to eq('json_fn')
          expect(json['result']).to eq({ 'count' => 100 })
          expect(json['duration_ms']).to be_a(Numeric)
          expect(json['billed_duration_ms']).to be_a(Integer)
          expect(json['memory_size_mb']).to eq(128)
        end
      end
    end

    it 'loads mock event data from file specified via --event' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'handler.rb'), <<~RUBY)
          def process(event:, context:)
            { received_user: event['user_id'] }
          end
        RUBY

        event_path = File.join(dir, 'event.json')
        File.write(event_path, JSON.generate({ user_id: 'usr_12345' }))

        fn = Veltrunode::Model::Function.new(:event_fn, handler: 'handler.process')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(['invoke', 'local', 'event_fn', '--event', event_path])
          expect(code).to eq(0)
          expect(stdout.string).to include('"received_user": "usr_12345"')
        end
      end
    end

    it 'loads mock event data from file specified via --event=path' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'handler.rb'), <<~RUBY)
          def process(event:, context:)
            { key: event['test_key'] }
          end
        RUBY

        event_path = File.join(dir, 'mock_evt.json')
        File.write(event_path, JSON.generate({ test_key: 'custom_val' }))

        fn = Veltrunode::Model::Function.new(:eq_evt_fn, handler: 'handler.process')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(['invoke', 'local', 'eq_evt_fn', "--event=#{event_path}"])
          expect(code).to eq(0)
          expect(stdout.string).to include('"key": "custom_val"')
        end
      end
    end

    it 'displays EFS warning in text mode and includes warning in JSON mode when mounts exist' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'handler.rb'), <<~RUBY)
          def process(event:, context:)
            { efs: 'test' }
          end
        RUBY

        arn = 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-0123456789abcdef0'
        mount = Veltrunode::Model::EfsMount.new(
          symbolic_name: 'storage',
          access_point_source: arn,
          local_path: '/mnt/storage'
        )
        fn = Veltrunode::Model::Function.new(:efs_fn, handler: 'handler.process', mounts: [mount])
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          # Text mode
          code = run_cli(%w[invoke local efs_fn])
          expect(code).to eq(0)
          warn_msg = 'EFS mount simulation is skipped in local execution (local limitation).'
          expect(stdout.string).to include("[WARN] #{warn_msg}")

          # JSON mode
          stdout.reopen
          code_json = run_cli(%w[invoke local efs_fn --format json])
          expect(code_json).to eq(0)
          json = JSON.parse(stdout.string)
          expect(json['warnings']).to include(warn_msg)
        end
      end
    end

    it 'returns exit code 2 when function name is missing' do
      code = run_cli(%w[invoke local])
      expect(code).to eq(2)
      expect(stderr.string).to include('Error: Function name is required for invoke local.')
    end

    it 'returns exit code 2 with structured JSON on missing function name when --format json is specified' do
      code = run_cli(%w[invoke local --format json])
      expect(code).to eq(2)
      json = JSON.parse(stderr.string)
      expect(json['status']).to eq('error')
      expect(json['error_code']).to eq(2)
      expect(json['message']).to eq('Function name is required for invoke local.')
    end

    it 'returns exit code 2 when specified function is not found in application' do
      app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [])
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

      code = run_cli(%w[invoke local unknown_fn])
      expect(code).to eq(2)
      expect(stderr.string).to include("Function 'unknown_fn' not found in application 'demo_app'.")
    end

    it 'returns exit code 2 when --event file does not exist' do
      fn = Veltrunode::Model::Function.new(:fn1, handler: 'handler.process')
      app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
      allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

      code = run_cli(%w[invoke local fn1 --event nonexistent_event.json])
      expect(code).to eq(2)
      expect(stderr.string).to include('Event file not found: nonexistent_event.json')
    end

    it 'returns exit code 2 when --event file contains invalid JSON' do
      Dir.mktmpdir do |dir|
        bad_json = File.join(dir, 'bad.json')
        File.write(bad_json, '{ invalid json')

        fn = Veltrunode::Model::Function.new(:fn1, handler: 'handler.process')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        code = run_cli(['invoke', 'local', 'fn1', '--event', bad_json])
        expect(code).to eq(2)
        expect(stderr.string).to include('Invalid JSON in event file')
      end
    end

    it 'returns exit code 2 when function execution times out' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'slow.rb'), <<~RUBY)
          def handle(event:, context:)
            sleep 2
          end
        RUBY

        fn = Veltrunode::Model::Function.new(:timeout_fn, handler: 'slow.handle', timeout: 1)
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(%w[invoke local timeout_fn])
          expect(code).to eq(2)
          expect(stderr.string).to include("Function 'timeout_fn' timed out after 1 seconds.")
        end
      end
    end

    it 'returns exit code 2 when handler execution raises an error' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'error.rb'), <<~RUBY)
          def handle(event:, context:)
            raise 'Database connection failed'
          end
        RUBY

        fn = Veltrunode::Model::Function.new(:err_fn, handler: 'error.handle')
        app = Veltrunode::Model::Application.new(name: 'demo_app', functions: [fn])
        allow(Veltrunode::SettingsLoader).to receive(:load).and_return(app)

        Dir.chdir(dir) do
          code = run_cli(%w[invoke local err_fn])
          expect(code).to eq(2)
          expect(stderr.string).to include('Database connection failed')
        end
      end
    end
  end
end
