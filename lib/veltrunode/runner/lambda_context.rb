# frozen_string_literal: true

require 'securerandom'

module Veltrunode
  class Runner
    # AWS Lambda の context オブジェクトを模倣するクラス
    class LambdaContext
      attr_reader :function_name,
                  :function_version,
                  :invoked_function_arn,
                  :memory_limit_in_mb,
                  :aws_request_id,
                  :log_group_name,
                  :log_stream_name,
                  :deadline_ms,
                  :client_context,
                  :identity

      def initialize(
        function_name:,
        function_version: '$LATEST',
        invoked_function_arn: nil,
        memory_limit_in_mb: 128,
        aws_request_id: nil,
        log_group_name: nil,
        log_stream_name: nil,
        timeout: 3,
        client_context: nil,
        identity: nil
      )
        @function_name = function_name.to_s
        @function_version = function_version.to_s
        @invoked_function_arn = invoked_function_arn || default_arn(@function_name)
        @memory_limit_in_mb = memory_limit_in_mb.to_i
        @aws_request_id = aws_request_id || SecureRandom.uuid
        @log_group_name = log_group_name || "/aws/lambda/#{@function_name}"
        @log_stream_name = log_stream_name || default_log_stream_name
        @timeout = timeout.to_f
        @deadline_ms = ((Time.now.to_f + @timeout) * 1000).round
        @client_context = client_context
        @identity = identity
      end

      # rubocop:disable-next Naming/AccessorMethodName
      def get_remaining_time_in_millis
        remaining = @deadline_ms - (Time.now.to_f * 1000).round
        remaining.positive? ? remaining : 0
      end

      alias remaining_time_in_millis get_remaining_time_in_millis

      def [](key)
        h = to_h
        h[key.to_s.to_sym]
      end

      def to_h
        {
          function_name: @function_name,
          function_version: @function_version,
          invoked_function_arn: @invoked_function_arn,
          memory_limit_in_mb: @memory_limit_in_mb,
          aws_request_id: @aws_request_id,
          log_group_name: @log_group_name,
          log_stream_name: @log_stream_name,
          deadline_ms: @deadline_ms,
          get_remaining_time_in_millis: get_remaining_time_in_millis
        }
      end

      private

      def default_arn(fn_name)
        "arn:aws:lambda:ap-northeast-1:123456789012:function:#{fn_name}"
      end

      def default_log_stream_name
        "#{Time.now.strftime('%Y/%m/%d')}/[$LATEST]#{SecureRandom.hex(16)}"
      end
    end
  end
end
