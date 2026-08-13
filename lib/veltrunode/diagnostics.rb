# frozen_string_literal: true

# TCA: Diagnostics レイヤー
#
# Transparent Compiler Architecture における "Diagnostics" フェーズを担います。
# Validation・Compiler・Build などの各フェーズが検出した問題を
# 構造化された Diagnostic オブジェクトとして収集し、CLI へ出力する責務を持ちます。
#
# 設計上の制約:
# - AWS SDK には依存しません（Pure なロジックのみ）。
# - 各診断結果は恒久的なエラーコード（VLT-<category>-<id> 形式）で識別します。
#   例: VLT-REF-001（未解決参照）, VLT-BUILD-HANDLER-NOT-FOUND（ハンドラー非存在）
# - Diagnostic オブジェクトは code, severity, summary, evidence,
#   suggested_action などの属性を持ちます。
# - ValidationError は diagnostics: [] として複数の Diagnostic を保持し、
#   CLI が構造化されたレポートとして出力します。
#
# 詳細: docs/20-transparent-compiler-architecture.md

require_relative 'diagnostics/error_code_registry'
require_relative 'diagnostics/diagnostic'

module Veltrunode
  module Diagnostics
  end
end
