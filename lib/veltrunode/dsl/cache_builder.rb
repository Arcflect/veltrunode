# frozen_string_literal: true

require_relative 'base_builder'

module Veltrunode
  module DSL
    # キャッシュ設定用 DSL ビルダー
    class CacheBuilder < BaseBuilder
      def initialize
        super
        @remote_config = {}
      end

      def remote(s3: nil, &)
        if block_given?
          builder = RemoteCacheBuilder.new
          builder.instance_eval(&)
          @remote_config = builder.build
        elsif s3
          @remote_config = { s3: s3 }
        end
      end

      def build
        { remote: @remote_config }
      end
    end

    # リモートキャッシュ設定用 DSL ビルダー
    class RemoteCacheBuilder < BaseBuilder
      def initialize
        super
        @s3_config = {}
      end

      def s3(bucket: nil, prefix: nil)
        @s3_config[:bucket] = bucket if bucket
        @s3_config[:prefix] = prefix if prefix
      end

      def build
        { s3: @s3_config }
      end
    end
  end
end
