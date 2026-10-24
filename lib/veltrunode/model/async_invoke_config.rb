# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Model
    # Lambda 関数の非同期呼び出し設定（EventInvokeConfig）定義モデル
    class AsyncInvokeConfig
      MIN_RETRIES = 0
      MAX_RETRIES = 2
      MIN_EVENT_AGE = 60
      MAX_EVENT_AGE = 21_600
      DEFAULT_QUALIFIER = '$LATEST'

      attr_reader :max_retries,
                  :max_age,
                  :on_success,
                  :on_failure,
                  :qualifier

      alias maximum_retry_attempts max_retries
      alias maximum_event_age_in_seconds max_age

      def initialize(
        max_retries: nil,
        maximum_retry_attempts: nil,
        max_age: nil,
        max_age_seconds: nil,
        maximum_event_age_in_seconds: nil,
        on_success: nil,
        on_failure: nil,
        destination: nil,
        qualifier: DEFAULT_QUALIFIER
      )
        retries_val = maximum_retry_attempts.nil? ? max_retries : maximum_retry_attempts
        age_val = maximum_event_age_in_seconds || max_age_seconds || max_age

        success_dest = on_success || extract_dest(destination, :on_success)
        failure_dest = on_failure || extract_dest(destination, :on_failure)

        @max_retries = normalize_retries(retries_val)
        @max_age = normalize_age(age_val)
        @on_success = normalize_destination(success_dest)
        @on_failure = normalize_destination(failure_dest)
        @qualifier = (qualifier || DEFAULT_QUALIFIER).to_s.strip.freeze

        validate!
        freeze
      end

      def destination_config?
        !@on_success.nil? || !@on_failure.nil?
      end

      def to_h
        res = {}
        res['maximum_retry_attempts'] = @max_retries unless @max_retries.nil?
        res['maximum_event_age_in_seconds'] = @max_age unless @max_age.nil?
        res['qualifier'] = @qualifier unless @qualifier.nil? || @qualifier == DEFAULT_QUALIFIER
        if destination_config?
          dest = {}
          dest['on_success'] = deep_freeze_val(@on_success) if @on_success
          dest['on_failure'] = deep_freeze_val(@on_failure) if @on_failure
          res['destination_config'] = dest
        end
        res
      end

      # 送信先種別の判定 (:sqs, :sns, :event_bridge, :lambda, :unknown)
      def self.destination_type(dest)
        return :unknown if dest.nil?

        if dest.is_a?(Hash)
          return :sqs if dest.key?(:sqs) || dest.key?('sqs') || dest.key?(:queue) || dest.key?('queue')
          return :sns if dest.key?(:sns) || dest.key?('sns') || dest.key?(:topic) || dest.key?('topic')

          if dest.key?(:events) || dest.key?('events') || dest.key?(:event_bridge) || dest.key?('event_bridge')
            return :event_bridge
          end
          return :lambda if dest.key?(:lambda) || dest.key?('lambda') || dest.key?(:function) || dest.key?('function')

          str_val = dest.values.first.to_s
          return destination_type_from_string(str_val)
        end

        destination_type_from_string(dest.to_s)
      end

      def self.destination_type_from_string(str)
        case str
        when /:sqs:/
          :sqs
        when /:sns:/
          :sns
        when /:events:/
          :event_bridge
        when /:lambda:/
          :lambda
        else
          :unknown
        end
      end

      private

      def extract_dest(destination, key)
        return nil unless destination.is_a?(Hash)

        destination[key] || destination[key.to_s]
      end

      def normalize_retries(val)
        return nil if val.nil?

        val.to_i
      end

      def normalize_age(val)
        return nil if val.nil?

        val.to_i
      end

      def normalize_destination(dest)
        return nil if dest.nil?

        case dest
        when String
          s = dest.strip
          raise ValidationError, 'Destination cannot be blank' if s.empty?

          s.freeze
        when Hash
          raise ValidationError, 'Destination cannot be empty' if dest.empty?

          deep_freeze_val(dest)
        when Symbol
          dest
        else
          raise ValidationError, "Unsupported destination format: #{dest.inspect}"
        end
      end

      def deep_freeze_val(val)
        case val
        when Hash
          val.each_with_object({}) do |(k, v), memo|
            memo[k.is_a?(Symbol) ? k : k.to_s.freeze] = deep_freeze_val(v)
          end.freeze
        when Array
          val.map { |v| deep_freeze_val(v) }.freeze
        when String
          val.freeze
        else
          val
        end
      end

      def validate!
        validate_retries!
        validate_age!
        validate_presence!
      end

      def validate_retries!
        return if @max_retries.nil?

        return if @max_retries.between?(MIN_RETRIES, MAX_RETRIES)

        raise ValidationError,
              "Maximum retry attempts must be between #{MIN_RETRIES} and #{MAX_RETRIES}, got #{@max_retries}"
      end

      def validate_age!
        return if @max_age.nil?

        return if @max_age.between?(MIN_EVENT_AGE, MAX_EVENT_AGE)

        raise ValidationError,
              "Maximum event age must be between #{MIN_EVENT_AGE} and #{MAX_EVENT_AGE} seconds, got #{@max_age}"
      end

      def validate_presence!
        return unless @max_retries.nil? && @max_age.nil? && @on_success.nil? && @on_failure.nil?

        raise ValidationError,
              'AsyncInvokeConfig must specify at least one of max_retries, max_age, on_success, or on_failure'
      end
    end
  end
end
