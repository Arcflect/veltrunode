# frozen_string_literal: true

require_relative '../../diagnostics/diagnostic'

module Veltrunode
  module AWS
    module Inspectors
      class ConnectionInspector
        class << self
          def inspect(application, sts_client: nil, aws_region: nil)
            new(application, sts_client: sts_client, aws_region: aws_region).inspect
          end
        end

        attr_reader :application, :sts_client, :configured_region

        def initialize(application, sts_client: nil, aws_region: nil)
          @application = application
          @sts_client = sts_client
          @configured_region = aws_region
        end

        def inspect
          diagnostics = []

          check_region(diagnostics)

          client = resolve_sts_client
          unless client
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-AWS-AUTH-001',
              severity: :error,
              summary: 'AWS SDK (aws-sdk-sts) is not available or credentials could not be loaded.',
              suggested_action: 'Install aws-sdk-sts or configure valid AWS credentials and retry.',
              evidence: { 'region' => application_region }
            )
            return diagnostics
          end

          caller_identity = fetch_caller_identity(client)

          if caller_identity.is_a?(StandardError)
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-AWS-AUTH-001',
              severity: :error,
              summary: "AWS authentication failed: #{caller_identity.message}",
              suggested_action: 'Verify AWS credentials and permissions for STS:GetCallerIdentity.',
              evidence: { 'error' => caller_identity.message, 'region' => application_region }
            )
            return diagnostics
          end

          check_account(caller_identity, diagnostics)

          diagnostics
        end

        private

        def application_region
          if application.respond_to?(:region) && application.region
            application.region.to_s
          else
            'ap-northeast-1'
          end
        end

        def check_region(diagnostics)
          sdk_reg = resolve_sdk_region
          return if sdk_reg.nil? || sdk_reg.empty?

          expected = application_region
          return if sdk_reg == expected

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-AWS-REGION-001',
            severity: :error,
            summary: "AWS region mismatch: configured AWS SDK region '#{sdk_reg}' " \
                     "does not match application region '#{expected}'.",
            suggested_action: "Switch AWS_REGION or SDK configuration to '#{expected}' " \
                              'to match application settings.',
            evidence: { 'configured_region' => sdk_reg, 'application_region' => expected }
          )
        end

        def resolve_sdk_region
          return configured_region.to_s.strip if configured_region && !configured_region.to_s.strip.empty?

          if sts_client.respond_to?(:config) && sts_client.config.respond_to?(:region) && sts_client.config.region
            return sts_client.config.region.to_s.strip
          end

          return ENV.fetch('AWS_REGION', nil).to_s.strip if env_present?('AWS_REGION')
          return ENV.fetch('AWS_DEFAULT_REGION', nil).to_s.strip if env_present?('AWS_DEFAULT_REGION')

          if defined?(::Aws) && ::Aws.respond_to?(:config) && ::Aws.config[:region]
            return ::Aws.config[:region].to_s.strip
          end

          nil
        end

        def env_present?(key)
          val = ENV.fetch(key, nil)
          val && !val.to_s.strip.empty?
        end

        def check_account(caller_identity, diagnostics)
          current_account = extract_account(caller_identity)
          expected_account = application.respond_to?(:account_constraint) ? application.account_constraint : nil

          if expected_account && !expected_account.to_s.strip.empty?
            if current_account != expected_account.to_s.strip
              diagnostics << Diagnostics::Diagnostic.new(
                code: 'VLT-AWS-ACCOUNT-001',
                severity: :error,
                summary: "AWS account mismatch: current AWS caller account '#{current_account}' " \
                         "does not match expected constraint '#{expected_account}'.",
                suggested_action: "Switch to AWS credentials for account '#{expected_account}'.",
                evidence: { 'current_account' => current_account, 'expected_account' => expected_account }
              )
            end
          else
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-AWS-ACCOUNT-002',
              severity: :warning,
              summary: 'No account constraint specified in application configuration. ' \
                       "Operating against AWS account '#{current_account}' without verification.",
              suggested_action: "Specify 'account' constraint in Veltrunodefile to prevent accidental deployments.",
              evidence: { 'current_account' => current_account }
            )
          end
        end

        def resolve_sts_client
          return sts_client if sts_client

          begin
            require 'aws-sdk-sts' unless defined?(::Aws::STS::Client)
            ::Aws::STS::Client.new(region: application_region)
          rescue LoadError, StandardError
            nil
          end
        end

        def fetch_caller_identity(client)
          client.get_caller_identity
        rescue StandardError => e
          e
        end

        def extract_account(caller_identity)
          if caller_identity.respond_to?(:account)
            caller_identity.account.to_s
          elsif caller_identity.is_a?(Hash)
            (caller_identity[:account] || caller_identity['account'] || caller_identity['Account']).to_s
          else
            caller_identity.to_s
          end
        end
      end
    end
  end
end
