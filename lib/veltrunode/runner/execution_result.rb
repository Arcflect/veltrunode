# frozen_string_literal: true

module Veltrunode
  class Runner
    # ローカル実行結果およびメタデータを保持するクラス
    class ExecutionResult
      attr_reader :result,
                  :duration_ms,
                  :billed_duration_ms,
                  :memory_size_mb,
                  :function_name,
                  :warnings

      def initialize(
        result:,
        duration_ms:,
        memory_size_mb:,
        function_name:,
        warnings: []
      )
        @result = result
        @duration_ms = duration_ms.to_f.round(2)
        @billed_duration_ms = [duration_ms.to_f.ceil, 1].max
        @memory_size_mb = memory_size_mb.to_i
        @function_name = function_name.to_s
        @warnings = Array(warnings).map(&:to_s).freeze
      end

      def success?
        true
      end

      def [](key)
        to_h[key.to_sym] || to_h[key.to_s]
      end

      def ==(other)
        if other.is_a?(ExecutionResult)
          to_h == other.to_h
        else
          result == other
        end
      end

      def to_h
        data = {
          status: 'success',
          function_name: @function_name,
          result: @result,
          duration_ms: @duration_ms,
          billed_duration_ms: @billed_duration_ms,
          memory_size_mb: @memory_size_mb
        }
        data[:warnings] = @warnings unless @warnings.empty?
        data
      end
    end
  end
end
