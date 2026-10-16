# frozen_string_literal: true

module Veltrunode
  module Model
    # EFSマウント通信用セキュリティグループ自動生成ヘルパーのモデル
    class SecurityGroupHelper
      attr_reader :symbolic_name,
                  :vpc_id,
                  :description,
                  :tags

      def initialize(
        symbolic_name: :default,
        vpc_id:,
        description: nil,
        tags: nil
      )
        validate!(symbolic_name: symbolic_name, vpc_id: vpc_id)

        @symbolic_name = (symbolic_name || :default).to_sym
        @vpc_id = normalize_vpc_id(vpc_id)
        @description = description&.to_s&.strip&.freeze
        @tags = tags ? freeze_hash(tags) : {}.freeze

        freeze
      end

      private

      def validate!(symbolic_name:, vpc_id:)
        if symbolic_name.nil? || symbolic_name.to_s.strip.empty?
          raise ValidationError, 'SecurityGroupHelper symbolic_name is required'
        end

        if vpc_id.nil? || (vpc_id.is_a?(String) && vpc_id.strip.empty?)
          raise ValidationError, 'SecurityGroupHelper vpc_id is required'
        end
      end

      def normalize_vpc_id(raw)
        if raw.is_a?(Hash)
          freeze_hash(raw)
        elsif raw.respond_to?(:name)
          # DSL::Reference 等
          raw
        elsif raw.is_a?(Symbol)
          raw
        else
          raw.to_s.strip.freeze
        end
      end

      def freeze_hash(hash)
        hash.each_with_object({}) do |(k, v), memo|
          frozen_val = if v.is_a?(Hash)
                         freeze_hash(v)
                       elsif v.is_a?(Array)
                         v.map { |item| item.is_a?(Hash) ? freeze_hash(item) : item.to_s.freeze }.freeze
                       else
                         v.to_s.freeze
                       end
          memo[k.to_s.freeze] = frozen_val
        end.freeze
      end
    end
  end
end
