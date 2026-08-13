# frozen_string_literal: true

# TCA: Validation レイヤー
#
# Transparent Compiler Architecture における "Validation" フェーズを担います。
# Internal Model（Application / Function / Layer 等）に対して動作する
# 純粋な検証チェック機能を提供します。
#
# 設計上の制約:
# - AWS SDK・外部 API には一切依存しません（Pure なロジックのみ）。
# - AWS リソースの実状態（EFS の存在確認など）に依存する検証は、
#   AWS Adapter 境界（aws/inspectors/）に配置し Preflight Check として分離します。
# - ValidationError は Diagnostic オブジェクトのコレクションを持ち、
#   Diagnostics レイヤーを通じて CLI へ構造化出力されます。
#
# 詳細: docs/20-transparent-compiler-architecture.md

require_relative 'validation/engine'

module Veltrunode
  class ValidationError < Error
    attr_reader :diagnostics

    def initialize(message = nil, diagnostics: [])
      @diagnostics = diagnostics.dup.freeze
      super(message)
    end
  end

  module Validation
  end
end
