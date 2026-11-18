# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'securerandom'
require 'stringio'
require_relative '../diagnostics/diagnostic'

module Veltrunode
  module AWS
    # Lambda から EFS への 4KB ランダム I/O および 1MB シーケンシャル I/O ベンチマークを実行するクラス
    class EfsBenchmarker
      RANDOM_BLOCK_SIZE = 4096 # 4 KB
      SEQUENTIAL_BLOCK_SIZE = 1_048_576 # 1 MB
      DEFAULT_RANDOM_ITERATIONS = 64
      DEFAULT_SEQUENTIAL_BLOCKS = 8

      BENCHMARK_RUBY_HANDLER = <<~RUBY
        require 'json'
        require 'fileutils'
        require 'securerandom'

        def handler(event:, context:)
          mount_path = event['mount_path'] || '/mnt/efs'
          rand_iters = (event['random_iterations'] || 64).to_i
          seq_blocks = (event['sequential_blocks'] || 8).to_i
          bench_dir = File.join(mount_path, ".veltrunode_bench_\#{SecureRandom.hex(6)}")
          FileUtils.mkdir_p(bench_dir)
          rand_file = File.join(bench_dir, 'random_4kb.bin')
          seq_file = File.join(bench_dir, 'sequential_1mb.bin')

          begin
            # 1. 4KB Random I/O
            block_4k = 'A' * 4096
            w_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            File.open(rand_file, 'wb+') do |f|
              rand_iters.times do |i|
                offset = ((i * 7) % rand_iters) * 4096
                f.seek(offset)
                f.write(block_4k)
                f.flush
              end
              f.fsync rescue nil
            end
            w_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - w_start, 0.000001].max

            r_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            File.open(rand_file, 'rb') do |f|
              rand_iters.times do |i|
                offset = ((i * 13) % rand_iters) * 4096
                f.seek(offset)
                f.read(4096)
              end
            end
            r_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - r_start, 0.000001].max

            # 2. 1MB Sequential I/O
            block_1m = 'B' * 1_048_576
            sw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            File.open(seq_file, 'wb') do |f|
              seq_blocks.times { f.write(block_1m) }
              f.flush
              f.fsync rescue nil
            end
            sw_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - sw_start, 0.000001].max

            sr_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            File.open(seq_file, 'rb') do |f|
              seq_blocks.times { f.read(1_048_576) }
            end
            sr_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - sr_start, 0.000001].max

            {
              'random_4kb' => {
                'block_size_bytes' => 4096,
                'iterations' => rand_iters,
                'write_latency_ms' => ((w_elapsed / rand_iters) * 1000.0).round(3),
                'read_latency_ms' => ((r_elapsed / rand_iters) * 1000.0).round(3),
                'write_iops' => (rand_iters / w_elapsed).round(2),
                'read_iops' => (rand_iters / r_elapsed).round(2),
                'write_throughput_mbps' => (((rand_iters * 4096) / 1_048_576.0) / w_elapsed).round(2),
                'read_throughput_mbps' => (((rand_iters * 4096) / 1_048_576.0) / r_elapsed).round(2)
              },
              'sequential_1mb' => {
                'block_size_bytes' => 1_048_576,
                'blocks' => seq_blocks,
                'write_latency_ms' => ((sw_elapsed / seq_blocks) * 1000.0).round(3),
                'read_latency_ms' => ((sr_elapsed / seq_blocks) * 1000.0).round(3),
                'write_throughput_mbps' => (seq_blocks / sw_elapsed).round(2),
                'read_throughput_mbps' => (seq_blocks / sr_elapsed).round(2)
              },
              'cleaned_up' => true
            }
          ensure
            FileUtils.rm_rf(bench_dir)
          end
        end
      RUBY

      # ベンチマーク結果を表す値オブジェクト
      class Report
        attr_reader :function_name, :mount_path, :region,
                    :random_4kb, :sequential_1mb,
                    :cleaned_up, :temp_function_name, :temp_function_deleted,
                    :diagnostics

        def initialize(
          function_name:,
          mount_path:,
          region:,
          random_4kb: {},
          sequential_1mb: {},
          cleaned_up: true,
          temp_function_name: nil,
          temp_function_deleted: true,
          diagnostics: []
        )
          @function_name = function_name.to_s.freeze
          @mount_path = mount_path.to_s.freeze
          @region = region.to_s.freeze
          @random_4kb = random_4kb.dup.freeze
          @sequential_1mb = sequential_1mb.dup.freeze
          @cleaned_up = cleaned_up ? true : false
          @temp_function_name = temp_function_name&.to_s&.freeze
          @temp_function_deleted = temp_function_deleted ? true : false
          @diagnostics = diagnostics.dup.freeze
          freeze
        end

        def cleaned_up?
          @cleaned_up
        end

        def temp_function_deleted?
          @temp_function_deleted
        end

        def success?
          @diagnostics.none? { |d| d.severity == :error }
        end

        def to_h
          {
            'function_name' => @function_name,
            'mount_path' => @mount_path,
            'region' => @region,
            'random_4kb' => @random_4kb,
            'sequential_1mb' => @sequential_1mb,
            'cleaned_up' => @cleaned_up,
            'temp_function_name' => @temp_function_name,
            'temp_function_deleted' => @temp_function_deleted
          }
        end
      end

      class << self
        def run(application = nil, function_name:, **)
          new(application, function_name: function_name, **).run
        end

        # 指定されたディレクトリ上で実際に 4KB ランダム I/O と 1MB シーケンシャル I/O を測定し、
        # 測定完了後にテストファイルを自動クリーンアップします。
        def run_io_benchmark(
          target_dir,
          random_iterations: DEFAULT_RANDOM_ITERATIONS,
          sequential_blocks: DEFAULT_SEQUENTIAL_BLOCKS
        )
          rand_iters = [random_iterations.to_i, 1].max
          seq_blocks = [sequential_blocks.to_i, 1].max
          bench_dir = File.join(target_dir, ".veltrunode_bench_#{SecureRandom.hex(6)}")
          FileUtils.mkdir_p(bench_dir)
          rand_file = File.join(bench_dir, 'random_4kb.bin')
          seq_file = File.join(bench_dir, 'sequential_1mb.bin')

          begin
            rand_stats = measure_random_4kb(rand_file, rand_iters)
            seq_stats = measure_sequential_1mb(seq_file, seq_blocks)
          ensure
            FileUtils.rm_rf(bench_dir)
          end
          cleaned_up = !File.exist?(bench_dir) && !File.exist?(rand_file) && !File.exist?(seq_file)

          {
            'random_4kb' => rand_stats,
            'sequential_1mb' => seq_stats,
            'cleaned_up' => cleaned_up,
            'removed_files' => [rand_file, seq_file]
          }
        end

        private

        def measure_random_4kb(file_path, iterations)
          block_4k = 'A' * RANDOM_BLOCK_SIZE

          w_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          File.open(file_path, 'wb+') do |f|
            iterations.times do |i|
              offset = ((i * 7) % iterations) * RANDOM_BLOCK_SIZE
              f.seek(offset)
              f.write(block_4k)
              f.flush
            end
          end
          w_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - w_start, 0.000001].max

          r_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          File.open(file_path, 'rb') do |f|
            iterations.times do |i|
              offset = ((i * 13) % iterations) * RANDOM_BLOCK_SIZE
              f.seek(offset)
              f.read(RANDOM_BLOCK_SIZE)
            end
          end
          r_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - r_start, 0.000001].max

          total_mb = (iterations * RANDOM_BLOCK_SIZE) / 1_048_576.0
          {
            'block_size_bytes' => RANDOM_BLOCK_SIZE,
            'iterations' => iterations,
            'write_latency_ms' => ((w_elapsed / iterations) * 1000.0).round(3),
            'read_latency_ms' => ((r_elapsed / iterations) * 1000.0).round(3),
            'write_iops' => (iterations / w_elapsed).round(2),
            'read_iops' => (iterations / r_elapsed).round(2),
            'write_throughput_mbps' => (total_mb / w_elapsed).round(2),
            'read_throughput_mbps' => (total_mb / r_elapsed).round(2)
          }
        end

        def measure_sequential_1mb(file_path, blocks)
          block_1m = 'B' * SEQUENTIAL_BLOCK_SIZE

          sw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          File.open(file_path, 'wb') do |f|
            blocks.times { f.write(block_1m) }
            f.flush
          end
          sw_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - sw_start, 0.000001].max

          sr_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          File.open(file_path, 'rb') do |f|
            blocks.times { f.read(SEQUENTIAL_BLOCK_SIZE) }
          end
          sr_elapsed = [Process.clock_gettime(Process::CLOCK_MONOTONIC) - sr_start, 0.000001].max

          {
            'block_size_bytes' => SEQUENTIAL_BLOCK_SIZE,
            'blocks' => blocks,
            'write_latency_ms' => ((sw_elapsed / blocks) * 1000.0).round(3),
            'read_latency_ms' => ((sr_elapsed / blocks) * 1000.0).round(3),
            'write_throughput_mbps' => (blocks / sw_elapsed).round(2),
            'read_throughput_mbps' => (blocks / sr_elapsed).round(2)
          }
        end
      end

      attr_reader :application, :function_name, :mount_path, :lambda_client, :configured_region,
                  :local_dir, :random_iterations, :sequential_blocks

      def initialize(
        application = nil,
        function_name:,
        mount_path: nil,
        lambda_client: nil,
        aws_region: nil,
        local_dir: nil,
        random_iterations: DEFAULT_RANDOM_ITERATIONS,
        sequential_blocks: DEFAULT_SEQUENTIAL_BLOCKS
      )
        @application = application
        @function_name = function_name.to_s.strip
        @configured_region = aws_region
        @lambda_client = lambda_client
        @local_dir = local_dir
        @random_iterations = random_iterations
        @sequential_blocks = sequential_blocks
        @mount_path = mount_path || resolve_mount_path
      end

      def run
        if local_dir
          res = self.class.run_io_benchmark(
            local_dir,
            random_iterations: random_iterations,
            sequential_blocks: sequential_blocks
          )
          return Report.new(
            function_name: function_name,
            mount_path: mount_path,
            region: region,
            random_4kb: res['random_4kb'],
            sequential_1mb: res['sequential_1mb'],
            cleaned_up: res['cleaned_up']
          )
        end

        client = resolve_lambda_client
        unless client
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-AWS-AUTH-001',
            severity: :error,
            summary: 'AWS SDK (aws-sdk-lambda) is not available or valid AWS credentials could not be loaded.',
            suggested_action: 'Install aws-sdk-lambda or configure valid AWS credentials.'
          )
          return Report.new(
            function_name: function_name,
            mount_path: mount_path,
            region: region,
            cleaned_up: false,
            diagnostics: [diag]
          )
        end

        execute_remote_benchmark(client)
      rescue StandardError => e
        diag = Diagnostics::Diagnostic.new(
          code: 'VLT-EFS-BENCH-FAILED',
          severity: :error,
          summary: "Failed to run EFS benchmark for function '#{function_name}': #{e.message}",
          suggested_action: 'Verify Lambda invoke/create permissions and ensure EFS is mounted properly.',
          evidence: { 'function_name' => function_name, 'mount_path' => mount_path, 'error' => e.message }
        )
        Report.new(
          function_name: function_name,
          mount_path: mount_path,
          region: region,
          cleaned_up: false,
          diagnostics: [diag]
        )
      end

      private

      def region
        return configured_region.to_s.strip if configured_region && !configured_region.to_s.strip.empty?
        return application.region.to_s if application.respond_to?(:region) && application.region

        ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || 'ap-northeast-1'
      end

      def resolve_mount_path
        if application.respond_to?(:functions) && application.functions
          fn = application.functions.find { |f| f.logical_name == function_name }
          if fn.respond_to?(:mounts) && !Array(fn.mounts).empty?
            first_mount = Array(fn.mounts).first
            path = extract_mount_local_path(first_mount)
            return path if path
          end
        end

        '/mnt/efs'
      end

      def extract_mount_local_path(mount_ref)
        if mount_ref.is_a?(Hash)
          explicit = mount_ref[:local_path] || mount_ref['local_path']
          return explicit if explicit

          m_name = mount_ref[:name] || mount_ref['name'] || mount_ref[:symbolic_name] || mount_ref['symbolic_name']
          return lookup_application_mount_path(m_name)
        elsif mount_ref.respond_to?(:local_path)
          return mount_ref.local_path
        elsif mount_ref.is_a?(String) && mount_ref.include?(':')
          return mount_ref.split(':', 2).last
        elsif mount_ref.is_a?(String) || mount_ref.is_a?(Symbol)
          return lookup_application_mount_path(mount_ref.to_s)
        end

        nil
      end

      def lookup_application_mount_path(name)
        return nil unless name && application.respond_to?(:mounts) && application.mounts

        m = Array(application.mounts).find { |item| item.symbolic_name.to_s == name.to_s }
        m ? m.local_path : "/mnt/#{name}"
      end

      def execute_remote_benchmark(client)
        temp_fn_name = nil
        temp_fn_deleted = true
        target_to_invoke = function_name
        parsed = {}

        if client.respond_to?(:create_function) && client.respond_to?(:delete_function)
          temp_fn_name = "#{function_name}-efs-bench-#{SecureRandom.hex(4)}"
          create_temporary_bench_function(client, temp_fn_name)
          target_to_invoke = temp_fn_name
        end

        begin
          payload = JSON.generate(
            'veltrunode_efs_bench' => true,
            'mount_path' => mount_path,
            'random_iterations' => random_iterations,
            'sequential_blocks' => sequential_blocks,
            'cleanup' => true
          )
          resp = client.invoke(
            function_name: target_to_invoke,
            invocation_type: 'RequestResponse',
            payload: payload
          )
          parsed = parse_invoke_payload(resp)
        ensure
          if temp_fn_name && client.respond_to?(:delete_function)
            begin
              client.delete_function(function_name: temp_fn_name)
            rescue StandardError
              temp_fn_deleted = false
            end
          end
        end

        build_report_from_payload(parsed, temp_fn_name, temp_fn_deleted)
      end

      def create_temporary_bench_function(client, temp_fn_name)
        fn_cfg = if client.respond_to?(:get_function_configuration)
                   client.get_function_configuration(function_name: function_name)
                 end
        role = fn_cfg.respond_to?(:role) ? fn_cfg.role : nil
        vpc_cfg = fn_cfg.respond_to?(:vpc_config) ? fn_cfg.vpc_config : nil
        fs_cfgs = fn_cfg.respond_to?(:file_system_configs) ? fn_cfg.file_system_configs : nil

        params = {
          function_name: temp_fn_name,
          runtime: 'ruby3.3',
          handler: 'bench.handler',
          role: role || 'arn:aws:iam::123456789012:role/efs-bench-role',
          timeout: 60,
          memory_size: 512,
          code: { zip_file: BENCHMARK_RUBY_HANDLER }
        }
        params[:vpc_config] = vpc_cfg if vpc_cfg
        params[:file_system_configs] = fs_cfgs if fs_cfgs
        client.create_function(params)
      end

      def parse_invoke_payload(resp)
        return {} if resp.nil?
        return resp if resp.is_a?(Hash)

        raw = if resp.respond_to?(:payload) && resp.payload
                p = resp.payload
                p.respond_to?(:read) ? p.read : p.to_s
              else
                resp.to_s
              end
        return {} if raw.nil? || raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def build_report_from_payload(parsed, temp_fn_name, temp_fn_deleted)
        rand_raw = parsed['random_4kb'] || parsed[:random_4kb] || {}
        seq_raw = parsed['sequential_1mb'] || parsed[:sequential_1mb] || {}
        cleaned = if parsed.key?('cleaned_up')
                    parsed['cleaned_up']
                  elsif parsed.key?(:cleaned_up)
                    parsed[:cleaned_up]
                  else
                    true
                  end

        rand_data = {
          'block_size_bytes' => (rand_raw['block_size_bytes'] || rand_raw[:block_size_bytes] || RANDOM_BLOCK_SIZE).to_i,
          'iterations' => (rand_raw['iterations'] || rand_raw[:iterations] || random_iterations).to_i,
          'write_latency_ms' => (rand_raw['write_latency_ms'] || rand_raw[:write_latency_ms] || 0.0).to_f,
          'read_latency_ms' => (rand_raw['read_latency_ms'] || rand_raw[:read_latency_ms] || 0.0).to_f,
          'write_iops' => (rand_raw['write_iops'] || rand_raw[:write_iops] || 0.0).to_f,
          'read_iops' => (rand_raw['read_iops'] || rand_raw[:read_iops] || 0.0).to_f,
          'write_throughput_mbps' =>
            (rand_raw['write_throughput_mbps'] || rand_raw[:write_throughput_mbps] || 0.0).to_f,
          'read_throughput_mbps' => (rand_raw['read_throughput_mbps'] || rand_raw[:read_throughput_mbps] || 0.0).to_f
        }

        seq_data = {
          'block_size_bytes' =>
            (seq_raw['block_size_bytes'] || seq_raw[:block_size_bytes] || SEQUENTIAL_BLOCK_SIZE).to_i,
          'blocks' => (seq_raw['blocks'] || seq_raw[:blocks] || sequential_blocks).to_i,
          'write_latency_ms' => (seq_raw['write_latency_ms'] || seq_raw[:write_latency_ms] || 0.0).to_f,
          'read_latency_ms' => (seq_raw['read_latency_ms'] || seq_raw[:read_latency_ms] || 0.0).to_f,
          'write_throughput_mbps' => (seq_raw['write_throughput_mbps'] || seq_raw[:write_throughput_mbps] || 0.0).to_f,
          'read_throughput_mbps' => (seq_raw['read_throughput_mbps'] || seq_raw[:read_throughput_mbps] || 0.0).to_f
        }

        Report.new(
          function_name: function_name,
          mount_path: mount_path,
          region: region,
          random_4kb: rand_data,
          sequential_1mb: seq_data,
          cleaned_up: cleaned,
          temp_function_name: temp_fn_name,
          temp_function_deleted: temp_fn_deleted
        )
      end

      def resolve_lambda_client
        return lambda_client if lambda_client

        begin
          require 'aws-sdk-lambda' unless defined?(::Aws::Lambda::Client)
          ::Aws::Lambda::Client.new(region: region)
        rescue LoadError, StandardError
          nil
        end
      end
    end
  end
end
