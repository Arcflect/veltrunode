# frozen_string_literal: true

require_relative 'stage_policy'

module Veltrunode
  module Model
    # 本番環境向けの組み込みポリシーパックおよびカスタムポリシーパックの管理クラス
    class PolicyPack
      PRODUCTION_RULES = {
        deny_wildcard_actions: true,
        require_dlq: true,
        require_log_retention: true,
        deny_public_storage: true
      }.freeze

      PACKS = {
        production: PRODUCTION_RULES,
        prod: PRODUCTION_RULES
      }.freeze

      class << self
        # 本番環境用組み込みポリシーパック（StagePolicy）を生成する
        #
        # @param stage [String, Symbol] 対象ステージ（デフォルト: 'production'）
        # @param overrides [Hash] ルールの上書きオプション
        # @return [StagePolicy]
        def production(stage = 'production', **overrides)
          rules = PRODUCTION_RULES.merge(overrides)
          StagePolicy.new(stage, pack_name: 'production', **rules)
        end

        # 名前から組み込みポリシーパックを解決する
        #
        # @param name [String, Symbol] ポリシーパック名 (:production など)
        # @param stage [String, Symbol, nil] 対象ステージ（未指定時はパック名をステージとして使用）
        # @param overrides [Hash] ルールの上書きオプション
        # @return [StagePolicy]
        def builtin(name, stage = nil, **overrides)
          key = name.to_s.downcase.to_sym
          unless PACKS.key?(key)
            raise ArgumentError, "Unknown policy pack '#{name}'. Available packs: #{available_packs.join(', ')}"
          end

          target_stage = stage || key.to_s
          rules = PACKS[key].merge(overrides)
          StagePolicy.new(target_stage, pack_name: key.to_s, **rules)
        end

        # 指定された名前の組み込みポリシーパックが存在するか判定する
        #
        # @param name [String, Symbol]
        # @return [Boolean]
        def builtin?(name)
          return false if name.nil?

          PACKS.key?(name.to_s.downcase.to_sym)
        end

        # 利用可能な組み込みポリシーパック名一覧を返す
        #
        # @return [Array<Symbol>]
        def available_packs
          [:production]
        end
      end
    end
  end
end
