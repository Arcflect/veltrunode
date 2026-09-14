# frozen_string_literal: true

require 'pathname'

module Veltrunode
  # ファイルパスの正規化ユーティリティ
  #
  # 連続スラッシュ (//)、カレントディレクトリ (./)、親ディレクトリ参照 (../)、
  # バックスラッシュ (\) などの冗長・非互換なパス要素を除去し、安全で一貫したパス表現へ正規化します。
  module PathNormalizer
    module_function

    # パスを正規化します。
    #
    # @param path [String, Pathname, #to_s, nil] 正規化対象のパス
    # @return [String] 正規化されたパス文字列
    def normalize(path)
      return '' if path.nil?

      str = path.to_s.strip
      return '' if str.empty?

      Pathname.new(str.tr('\\', '/')).cleanpath.to_s
    end
  end
end
