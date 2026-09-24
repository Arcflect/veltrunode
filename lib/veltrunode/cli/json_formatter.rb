# frozen_string_literal: true

require 'json'
require_relative '../dsl/secret_value'

module Veltrunode
  class CLI
    # TCA Layer: CLI
    # CLI コマンド実行結果を共通スキーマの JSON 形式へシリアライズし、
    # env(..., secret: true) でマークされた機密情報を自動マスクする責務を持つ。
    class JsonFormatter
      FILTERED_PLACEHOLDER = '[FILTERED]'

      class << self
        # 共通スキーマ形式の JSON 文字列を生成する
        #
        # @param command [String, Symbol] 実行コマンド名
        # @param status [String, Symbol] 'success' または 'error'
        # @param diagnostics [Array] 診断情報（Diagnostic オブジェクトまたは Hash の配列）
        # @param data [Hash] コマンド固有の結果データ
        # @return [String] jq でパース可能な JSON 文字列
        def format(command:, status:, diagnostics: [], data: {})
          payload = {
            'command' => command.to_s,
            'status' => status.to_s,
            'diagnostics' => format_diagnostics(diagnostics),
            'data' => format_data(data)
          }

          masked_payload = mask(payload)
          JSON.generate(masked_payload)
        end

        # データ構造内の機密情報を再帰的に自動マスクする
        def mask(obj)
          return FILTERED_PLACEHOLDER if obj.respond_to?(:secret?) && obj.secret?

          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), memo|
              memo[k.to_s] = mask(v)
            end
          when Array
            obj.map { |item| mask(item) }
          when String
            mask_string(obj)
          when Symbol
            mask_string(obj.to_s)
          when Numeric, TrueClass, FalseClass, NilClass
            obj
          else
            if obj.respond_to?(:to_h)
              mask(obj.to_h)
            else
              mask_string(obj.to_s)
            end
          end
        end

        private

        def format_diagnostics(diagnostics)
          Array(diagnostics).map do |d|
            if d.respond_to?(:to_h)
              d.to_h
            elsif d.is_a?(Hash)
              d
            else
              { 'severity' => 'error', 'summary' => d.to_s }
            end
          end
        end

        def format_data(data)
          return {} if data.nil?
          return data.to_h if data.respond_to?(:to_h) && !data.is_a?(Hash)
          return data if data.is_a?(Hash)

          { 'value' => data }
        end

        def mask_string(str)
          return str unless defined?(Veltrunode::DSL::SecretValue)

          result = str.dup
          secrets = Veltrunode::DSL::SecretValue.registry.to_a.sort_by { |s| -s.length }
          secrets.each do |sec|
            next if sec.empty?

            result = result.gsub(sec, FILTERED_PLACEHOLDER)
          end
          result
        end
      end
    end
  end
end
