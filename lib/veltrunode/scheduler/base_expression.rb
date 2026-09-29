# frozen_string_literal: true

require_relative 'errors'
require_relative 'timezone_helper'

module Veltrunode
  module Scheduler
    # スケジュール式の基底抽象クラス
    class BaseExpression
      attr_reader :raw_expression

      def initialize(raw_expression)
        @raw_expression = raw_expression.to_s.strip.freeze
      end

      # 基準日時から次回以降の実行予定日時を N 回分計算して返します
      #
      # @param count [Integer] 取得する次回実行時刻の回数
      # @param from_time [Time] 基準日時（未指定時は現在時刻）
      # @param timezone [String] IANA タイムゾーン識別子 (デフォルト: 'UTC')
      # @return [Array<Time>]
      def next_occurrences(count = 5, from_time: Time.now, timezone: 'UTC')
        raise NotImplementedError, "#{self.class.name}#next_occurrences must be implemented"
      end

      # 基準日時からの直近の次回実行日時を返します
      #
      # @param from_time [Time]
      # @param timezone [String]
      # @return [Time, nil]
      def next_occurrence(from_time: Time.now, timezone: 'UTC')
        next_occurrences(1, from_time: from_time, timezone: timezone).first
      end

      def to_s
        raw_expression
      end
    end
  end
end
