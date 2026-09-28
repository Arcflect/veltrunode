# frozen_string_literal: true

require_relative 'deprecation/deprecated_method'
require_relative 'deprecation/method_wrapper'

module Veltrunode
  # DSL機能等の非推奨（Deprecation）を管理するモジュール
  module Deprecation
    # 非推奨警告がエラーに昇格した際に発生する例外クラス
    class DeprecationError < Veltrunode::Error; end

    # クラスやモジュールに `deprecate` メソッドを提供するヘルパー
    module Helper
      def deprecate(method_name, deprecated_since:, removal_version:, alternative: nil)
        Veltrunode::Deprecation.deprecate(
          self,
          method_name,
          deprecated_since: deprecated_since,
          removal_version: removal_version,
          alternative: alternative
        )
      end
    end

    class << self
      # 登録された非推奨メソッドの一覧
      #
      # @return [Array<DeprecatedMethod>]
      def registry
        @registry ||= []
      end

      # 非推奨メソッドの一覧を取得します
      #
      # @return [Array<DeprecatedMethod>]
      def deprecated_methods
        registry.dup
      end

      # メソッドを非推奨として登録し、呼び出し時に警告またはエラーを発生させるラッパーを定義します
      #
      # @param target [Module, Class] 対象のモジュールまたはクラス
      # @param method_name [Symbol, String] 対象のメソッド名
      # @param deprecated_since [String] 非推奨となったバージョン
      # @param removal_version [String] 削除予定のバージョン
      # @param alternative [Symbol, String, nil] 推奨される代替手段
      # @return [DeprecatedMethod]
      def deprecate(target, method_name, deprecated_since:, removal_version:, alternative: nil)
        entry = DeprecatedMethod.new(
          target: target,
          method_name: method_name,
          deprecated_since: deprecated_since,
          removal_version: removal_version,
          alternative: alternative
        )
        registry << entry

        MethodWrapper.wrap(target, entry)
        entry
      end

      # 非推奨の警告を通知します
      #
      # @param message_or_entry [String, DeprecatedMethod]
      # @param deprecated_since [String, nil]
      # @param removal_version [String, nil]
      # @param alternative [String, nil]
      # @param caller_location [Thread::Backtrace::Location, String, nil]
      def warn(message_or_entry, deprecated_since: nil, removal_version: nil, alternative: nil, caller_location: nil)
        key = if message_or_entry.is_a?(DeprecatedMethod)
                "#{message_or_entry.target}##{message_or_entry.method_name}"
              else
                message_or_entry.to_s
              end

        msg = if message_or_entry.is_a?(DeprecatedMethod)
                message_or_entry.message(caller_location: caller_location)
              elsif deprecated_since && removal_version
                build_message(
                  message_or_entry,
                  deprecated_since: deprecated_since,
                  removal_version: removal_version,
                  alternative: alternative,
                  caller_location: caller_location
                )
              else
                message_or_entry.to_s
              end

        notify(msg, key: key)
      end

      # 警告メッセージを処理します（エラー昇格または出力）
      #
      # @param message [String]
      # @param key [String, nil] 重複判定用のキー
      def notify(message, key: nil)
        msg = message.to_s
        dedup_key = key || msg

        raise DeprecationError, msg if error_mode?
        return if duplicate_warning?(dedup_key)

        emit_warning(msg)
      end

      # エラー昇格モードであるかどうかを判定します
      #
      # @return [Boolean]
      def error_mode?
        return true if @behavior == :error

        ENV['VELTRUNODE_DEPRECATION']&.strip&.downcase == 'error'
      end

      # 動作モードを設定します (:warn, :error, :silence)
      attr_writer :behavior

      # 警告の出力先を設定します（nil の場合は Kernel.warn）
      attr_accessor :output

      # 状態をリセットします（テスト用）
      def reset!
        @registry = []
        @seen_warnings = Set.new
        @behavior = nil
        @output = nil
      end

      private

      def seen_warnings
        @seen_warnings ||= Set.new
      end

      def duplicate_warning?(key)
        !seen_warnings.add?(key)
      end

      def emit_warning(message)
        if @behavior == :silence
          nil
        elsif @output.respond_to?(:puts)
          @output.puts(message)
        else
          Kernel.warn(message)
        end
      end

      def build_message(name, deprecated_since:, removal_version:, alternative: nil, caller_location: nil)
        msg = "[DEPRECATION WARNING] `#{name}` is deprecated since version #{deprecated_since} " \
              "and will be removed in version #{removal_version}."
        msg += " Please use `#{alternative}` instead." if alternative && !alternative.to_s.empty?
        msg += " (called from #{caller_location})" if caller_location
        msg
      end
    end
  end

  DeprecationError = Deprecation::DeprecationError
end
