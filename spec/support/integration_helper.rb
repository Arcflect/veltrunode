# frozen_string_literal: true

require 'securerandom'
require 'open3'
require 'json'
require 'veltrunode'

module IntegrationHelper
  class << self
    def tracked_stacks
      @tracked_stacks ||= []
    end

    def register_stack(stack_name)
      tracked_stacks << stack_name unless tracked_stacks.include?(stack_name)
    end

    def generate_app_name(prefix = 'integ')
      "vlt-#{prefix}-#{SecureRandom.hex(4)}"
    end

    def aws_configured?
      return false if ENV['AWS_REGION'].to_s.strip.empty?
      return false if ENV['AWS_ACCOUNT_ID'].to_s.strip.empty?
      return false if ENV['VELTRUNODE_TEST_ARTIFACT_BUCKET'].to_s.strip.empty?

      true
    end

    def container_available?
      exe = Veltrunode::Build::ContainerRunner.detect_executable
      return false unless exe

      _stdout, _stderr, status = Open3.capture3(exe, 'info')
      status.success?
    rescue StandardError
      false
    end

    def efs_configured?
      aws_configured? &&
        !ENV['VELTRUNODE_TEST_EFS_ACCESS_POINT'].to_s.strip.empty? &&
        !ENV['VELTRUNODE_TEST_SUBNET_IDS'].to_s.strip.empty? &&
        !ENV['VELTRUNODE_TEST_SECURITY_GROUP_IDS'].to_s.strip.empty?
    end

    def cleanup_stack(application, source_dir: nil, options: {})
      return unless application

      stack_name = application.name
      puts "\n[IntegrationHelper] Cleaning up stack '#{stack_name}'..."

      destroy_opts = {
        'auto_approve' => true,
        'quiet' => true
      }.merge(options.transform_keys(&:to_s))

      result = Veltrunode::Destroy::Pipeline.execute(
        application,
        source_dir: source_dir,
        options: destroy_opts
      )

      tracked_stacks.delete(stack_name)
      result
    rescue StandardError => e
      warn "[IntegrationHelper] Warning: Failed to destroy stack '#{stack_name}': #{e.message}"
      nil
    end

    def invoke_lambda(function_name, payload = {}, region: nil)
      reg = region || ENV.fetch('AWS_REGION', 'ap-northeast-1')

      if defined?(::Aws::Lambda::Client)
        client = ::Aws::Lambda::Client.new(region: reg)
        resp = client.invoke(
          function_name: function_name,
          invocation_type: 'RequestResponse',
          payload: JSON.generate(payload)
        )
        payload_str = resp.payload.read
        {
          status_code: resp.status_code,
          payload: JSON.parse(payload_str),
          raw_payload: payload_str
        }
      else
        # AWS CLI fallback
        out_file = Tempfile.new(['lambda-invoke', '.json'])
        cli_cmd = [
          'aws', 'lambda', 'invoke',
          '--region', reg,
          '--function-name', function_name,
          '--payload', JSON.generate(payload),
          '--cli-binary-format', 'raw-in-base64-out',
          out_file.path
        ]
        _stdout, stderr, status = Open3.capture3(*cli_cmd)
        raise "Failed to invoke Lambda '#{function_name}' via CLI: #{stderr}" unless status.success?

        content = out_file.read
        out_file.unlink
        {
          status_code: 200,
          payload: JSON.parse(content),
          raw_payload: content
        }
      end
    end
  end
end
