# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/security_group_helper'

module Veltrunode
  module DSL
    class SecurityGroupHelperBuilder < BaseBuilder
      attr_reader :symbolic_name

      def initialize(name = :default, vpc_id: nil, description: nil, tags: nil)
        super()
        @symbolic_name = (name || :default).to_sym
        @vpc_id = vpc_id
        @description = description
        @tags = tags ? tags.dup : {}
      end

      def vpc_id(val = nil)
        return @vpc_id if val.nil?

        @vpc_id = val
      end

      def description(val = nil)
        return @description if val.nil?

        @description = val.to_s
      end

      def tags(hash = nil)
        return @tags if hash.nil?

        @tags.merge!(hash)
      end

      def tag(key, value)
        @tags[key.to_s] = value.to_s
      end

      def build
        Model::SecurityGroupHelper.new(
          symbolic_name: @symbolic_name,
          vpc_id: @vpc_id,
          description: @description,
          tags: @tags
        )
      end
    end
  end
end
