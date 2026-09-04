# frozen_string_literal: true

# TCA: Artifact Generation レイヤー（Build サブシステム）
#
# Transparent Compiler Architecture における "Artifact Generation" フェーズを担います。
# Internal Model を入力として受け取り、Lambda 関数の ZIP パッケージや
# Layer の ZIP アーカイブを生成するビルドサブシステムです。
#
# 設計上の制約:
# - DeterministicArchiver を使用し、同一入力から常に同一の ZIP を生成します
#   （byte-for-byte の決定論的生成）。
# - AWS SDK には依存しません。AWS へのアップロードは deploy/ レイヤーが担います。
# - FunctionPackager はハンドラー検証・除外ルール・シンボリックリンク検証・
#   SecretScanner による機密情報スキャンを実施します。
# - File System への書き込みは副作用として明示的に扱います。
#
# 詳細: docs/20-transparent-compiler-architecture.md

require_relative 'build/archive_result'
require_relative 'build/deterministic_archiver'
require_relative 'build/package_result'
require_relative 'build/secret_scanner'
require_relative 'build/function_packager'
require_relative 'build/layer_package_result'
require_relative 'build/layer_packager'
require_relative 'build/container_runner'
require_relative 'build/native_builder'
require_relative 'build/cache'
require_relative 'build/build_result'
require_relative 'build/pipeline'

module Veltrunode
  module Build
    class << self
      def execute(application, **)
        Pipeline.execute(application, **)
      end
    end
  end
end
