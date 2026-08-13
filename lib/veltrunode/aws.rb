# frozen_string_literal: true

# TCA: AWS Adapter レイヤー（Side Effect 境界）
#
# Transparent Compiler Architecture における "AWS / Infrastructure Adapters" レイヤーです。
# AWS SDK を直接扱うことが許可されている唯一のレイヤーです。
#
# 設計上の制約:
# - このレイヤーは副作用境界（Side Effect Boundary）として明示的に扱います。
# - 読み取り専用の検証処理（Preflight Check）は aws/inspectors/ に配置します。
#   例: EFS アクセスポイント確認, AWS アカウント一致チェック, 変更セット検証
# - Internal Model（model/）・Validation（validation/）・Compiler（compiler/）からは
#   このレイヤーへの直接依存を禁じます（依存方向の固定: TCA 原則 7）。
# - AWS API のレスポンスを Internal Model へ変換する場合は Adapter パターンを用い、
#   モデル側に AWS 固有の型が侵入しないようにします。
#
# 詳細: docs/20-transparent-compiler-architecture.md

module Veltrunode
  module AWS
  end
end
