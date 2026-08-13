# frozen_string_literal: true

# TCA: Infrastructure Compiler レイヤー
#
# Transparent Compiler Architecture における "Artifact / Infrastructure Compiler"
# フェーズを担います。Internal Model を入力として受け取り、
# CloudFormation テンプレート（template.yml）へ変換する責務を持ちます。
#
# 設計上の制約:
# - 決定論的変換を保証します。正規化済みモデルとアーティファクトのハッシュ値が
#   同一であれば、常に同一の CloudFormation テンプレートを生成します。
# - AWS SDK には依存しません。テンプレートの生成はメモリ内の変換処理のみです。
# - AWS API 呼び出しはこのレイヤーでは行いません（deploy/ に委譲します）。
# - Internal Model（Function, Layer, Schedule 等）から CloudFormation リソース型
#   （AWS::Lambda::Function, AWS::Lambda::LayerVersion 等）へのマッピングを
#   明確に定義します。
#
# 詳細: docs/20-transparent-compiler-architecture.md

module Veltrunode
  module Compiler
  end
end
