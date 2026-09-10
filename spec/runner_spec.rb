# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Veltrunode::Runner do
  describe Veltrunode::Runner::LambdaContext do
    let(:context) do
      described_class.new(
        function_name: 'test_func',
        memory_limit_in_mb: 256,
        timeout: 5
      )
    end

    it 'initializes attributes with default values and generates UUID for request_id' do
      expect(context.function_name).to eq('test_func')
      expect(context.function_version).to eq('$LATEST')
      expect(context.invoked_function_arn).to include('test_func')
      expect(context.memory_limit_in_mb).to eq(256)
      expect(context.aws_request_id).to match(/\A[0-9a-f-]{36}\z/i)
      expect(context.log_group_name).to eq('/aws/lambda/test_func')
      expect(context.log_stream_name).to include('[$LATEST]')
      expect(context.deadline_ms).to be > (Time.now.to_f * 1000)
    end

    it 'calculates remaining time in milliseconds correctly' do
      remaining = context.get_remaining_time_in_millis
      expect(remaining).to be_positive
      expect(remaining).to be <= 5000
      expect(context.remaining_time_in_millis).to eq(remaining)
    end

    it 'supports hash-like access via symbol and string keys' do
      expect(context[:function_name]).to eq('test_func')
      expect(context['function_name']).to eq('test_func')
      expect(context[:memory_limit_in_mb]).to eq(256)
    end

    it 'converts to hash representation' do
      hash = context.to_h
      expect(hash[:function_name]).to eq('test_func')
      expect(hash[:memory_limit_in_mb]).to eq(256)
      expect(hash[:get_remaining_time_in_millis]).to be_a(Integer)
    end
  end

  describe Veltrunode::Runner::ExecutionResult do
    let(:result) do
      described_class.new(
        result: { 'status' => 'ok' },
        duration_ms: 12.345,
        memory_size_mb: 128,
        function_name: 'hello_fn',
        warnings: ['EFS warning']
      )
    end

    it 'exposes execution metadata and calculates billed duration' do
      expect(result.result).to eq({ 'status' => 'ok' })
      expect(result.duration_ms).to eq(12.35)
      expect(result.billed_duration_ms).to eq(13)
      expect(result.memory_size_mb).to eq(128)
      expect(result.function_name).to eq('hello_fn')
      expect(result.warnings).to eq(['EFS warning'])
      expect(result.success?).to be true
    end

    it 'compares equality with raw handler return value and other ExecutionResult' do
      expect(result).to eq({ 'status' => 'ok' })
      same = described_class.new(
        result: { 'status' => 'ok' },
        duration_ms: 12.345,
        memory_size_mb: 128,
        function_name: 'hello_fn',
        warnings: ['EFS warning']
      )
      expect(result).to eq(same)
    end

    it 'converts to JSON-serializable hash' do
      hash = result.to_h
      expect(hash[:status]).to eq('success')
      expect(hash[:function_name]).to eq('hello_fn')
      expect(hash[:result]).to eq({ 'status' => 'ok' })
      expect(hash[:warnings]).to eq(['EFS warning'])
    end
  end

  describe '.run' do
    it 'executes a Ruby handler method accepting keyword arguments (event:, context:)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'hello.rb'), <<~RUBY)
          def handler(event:, context:)
            { status: 200, received: event[:val], req_id: context.aws_request_id }
          end
        RUBY

        func = Veltrunode::Function.new(:hello)
        func.handler = 'hello.handler'
        func.runtime = 'ruby3.2'

        res = described_class.run(func, { val: 'abc' }, source_dir: dir)
        expect(res.result[:status]).to eq(200)
        expect(res.result[:received]).to eq('abc')
        expect(res.result[:req_id]).to match(/\A[0-9a-f-]{36}\z/i)
        expect(res.duration_ms).to be >= 0
      end
    end

    it 'executes a Ruby handler method accepting positional arguments (event, context)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'positional.rb'), <<~RUBY)
          def my_handler(event, context)
            { count: event['count'], fn: context[:function_name] }
          end
        RUBY

        func = Veltrunode::Function.new(:pos_fn)
        func.handler = 'positional.my_handler'
        func.runtime = 'ruby3.2'

        res = described_class.run(func, { 'count' => 42 }, source_dir: dir)
        expect(res.result).to eq({ count: 42, fn: 'pos_fn' })
      end
    end

    it 'sets standard AWS Lambda and custom function environment variables, then restores ENV' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'env_check.rb'), <<~RUBY)
          def check_env(event:, context:)
            {
              fn_name: ENV['AWS_LAMBDA_FUNCTION_NAME'],
              region: ENV['AWS_REGION'],
              mem: ENV['AWS_LAMBDA_FUNCTION_MEMORY_SIZE'],
              custom: ENV['CUSTOM_KEY']
            }
          end
        RUBY

        func = Veltrunode::Function.new(
          :env_fn,
          environment: { 'CUSTOM_KEY' => 'custom_value' },
          memory: 512
        )
        func.handler = 'env_check.check_env'
        func.runtime = 'ruby3.2'

        app = Veltrunode::Model::Application.new(
          name: 'my-app',
          region: 'us-east-1',
          stage: 'prod',
          functions: [func]
        )

        original_env_name = ENV.fetch('AWS_LAMBDA_FUNCTION_NAME', nil)
        original_custom = ENV.fetch('CUSTOM_KEY', nil)

        res = described_class.run(func, {}, application: app, source_dir: dir)
        expect(res.result[:fn_name]).to eq('env_fn')
        expect(res.result[:region]).to eq('us-east-1')
        expect(res.result[:mem]).to eq('512')
        expect(res.result[:custom]).to eq('custom_value')

        expect(ENV.fetch('AWS_LAMBDA_FUNCTION_NAME', nil)).to eq(original_env_name)
        expect(ENV.fetch('CUSTOM_KEY', nil)).to eq(original_custom)
      end
    end

    it 'simulates timeout and raises TimeoutError when execution exceeds timeout' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'slow.rb'), <<~RUBY)
          def slow_handler(event:, context:)
            sleep 2
            { status: 'done' }
          end
        RUBY

        func = Veltrunode::Function.new(:slow_fn, timeout: 1)
        func.handler = 'slow.slow_handler'
        func.runtime = 'ruby3.2'

        expect do
          described_class.run(func, {}, source_dir: dir)
        end.to raise_error(Veltrunode::Runner::TimeoutError, /Function 'slow_fn' timed out after 1 seconds\./)
      end
    end

    it 'detects EFS mounts and sets warning in ExecutionResult' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'efs_fn.rb'), <<~RUBY)
          def handler(event:, context:)
            { efs: 'skipped' }
          end
        RUBY

        arn = 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-0123456789abcdef0'
        mount = Veltrunode::Model::EfsMount.new(
          symbolic_name: 'data_mount',
          access_point_source: arn,
          local_path: '/mnt/data'
        )
        func = Veltrunode::Function.new(:efs_func, mounts: [mount])
        func.handler = 'efs_fn.handler'
        func.runtime = 'ruby3.2'

        res = described_class.run(func, {}, source_dir: dir)
        expect(res.result).to eq({ efs: 'skipped' })
        expect(res.warnings).to include('EFS mount simulation is skipped in local execution (local limitation).')
      end
    end

    it 'raises Veltrunode::Error when handler file does not exist' do
      func = Veltrunode::Function.new(:missing_fn)
      func.handler = 'nonexistent.handler'
      func.runtime = 'ruby3.2'

      expect do
        described_class.run(func, {})
      end.to raise_error(Veltrunode::Error, /Ruby file not found/)
    end

    it 'raises Veltrunode::Error when handler method is not defined' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'empty.rb'), "# no methods\n")

        func = Veltrunode::Function.new(:undef_fn)
        func.handler = 'empty.not_found_method'
        func.runtime = 'ruby3.2'

        expect do
          described_class.run(func, {}, source_dir: dir)
        end.to raise_error(Veltrunode::Error, /Handler method 'not_found_method' not defined/)
      end
    end

    it 'raises Veltrunode::Error on invalid handler format' do
      func = Veltrunode::Function.new(:bad_format)
      func.handler = 'invalid_format'

      expect do
        described_class.run(func, {})
      end.to raise_error(Veltrunode::Error, /Invalid handler format/)
    end
  end
end
