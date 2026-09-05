# frozen_string_literal: true

require_relative '../../diagnostics/diagnostic'

module Veltrunode
  module AWS
    module Inspectors
      class ConnectionInspector
        class << self
          def inspect(application, sts_client: nil)
            new(application, sts_client: sts_client).inspect
          end
        end

        attr_reader :application, :sts_client

        def initialize(application, sts_client: nil)
          @application = application
          @sts_client = sts_client
        end

        def inspect
          diagnostics = []

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

          current_account = extract_account(caller_identity)
          expected_account = application.respond_to?(:account_constraint) ? application.account_constraint : nil

          if expected_account && !expected_account.to_s.strip.empty? && (current_account != expected_account.to_s.strip)
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-AWS-ACCOUNT-001',
              severity: :error,
              summary: "AWS account mismatch: current AWS caller account '#{current_account}' " \
                       "does not match expected constraint '#{expected_account}'.",
              suggested_action: "Switch to AWS credentials for account '#{expected_account}'.",
              evidence: { 'current_account' => current_account, 'expected_account' => expected_account }
            )
          end

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
