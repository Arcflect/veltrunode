# frozen_string_literal: true

# TCA: Internal Model レイヤー
#
# Transparent Compiler Architecture における "Internal Model" フェーズを担います。
# DSL や CLI の入力を、Validation・Dependency Resolution・Compilation が
# 処理しやすい型付きオブジェクトへ変換する責務を持ちます。
#
# 設計上の制約:
# - Pure Ruby PORO として設計します。AWS SDK には一切依存しません。
# - 不変（freeze）を原則とし、フェーズ間でのミューテートを禁じます。
# - CloudFormation のハッシュ構造に直接依存してはなりません。
#
# 詳細: docs/20-transparent-compiler-architecture.md

require_relative 'model/application'
require_relative 'model/function'
require_relative 'model/layer'
require_relative 'model/schedule'
require_relative 'model/efs_mount'
require_relative 'model/capability'
require_relative 'model/capability_expander'

module Veltrunode
  module Model
  end

  Application = Model::Application
  Function = Model::Function
  Layer = Model::Layer
  Schedule = Model::Schedule
  EfsMount = Model::EfsMount
  Capability = Model::Capability
  CapabilityExpander = Model::CapabilityExpander
end
