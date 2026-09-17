# frozen_string_literal: true

require_relative 'inspectors/connection_inspector'

module Veltrunode
  module AWS
    class AccountRegionMismatchError < StandardError
      attr_reader :diagnostics

      def initialize(message = 'AWS account or region verification failed', diagnostics: [])
        super(message)
        @diagnostics = diagnostics.dup.freeze
      end
    end

    class AccountRegionGuard
      class << self
        def check(application, sts_client: nil, aws_region: nil)
          new(application, sts_client: sts_client, aws_region: aws_region).check
        end

        def check!(application, sts_client: nil, aws_region: nil)
          new(application, sts_client: sts_client, aws_region: aws_region).check!
        end
      end

      attr_reader :application, :sts_client, :aws_region

      def initialize(application, sts_client: nil, aws_region: nil)
        @application = application
        @sts_client = sts_client
        @aws_region = aws_region
      end

      def check
        Inspectors::ConnectionInspector.inspect(
          application,
          sts_client: sts_client,
          aws_region: aws_region
        )
      end

      def check!
        diagnostics = check
        errors = diagnostics.select { |d| d.severity == :error }

        unless errors.empty?
          summary = errors.map(&:summary).join('; ')
          raise AccountRegionMismatchError.new(
            "AWS account/region verification failed: #{summary}",
            diagnostics: diagnostics
          )
        end

        diagnostics
      end
    end
  end
end
