# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/subscription_filter'

module Veltrunode
  module DSL
    # 個別サブスクリプションフィルター用 DSL ビルダー
    class SubscriptionFilterBuilder < BaseBuilder
      def initialize(name = nil)
        super()
        @name = name&.to_sym
        @destination = nil
        @filter_pattern = ''
        @destination_type = :auto
        @role_arn = nil
        @distribution = nil
      end

      def destination(dest)
        @destination = dest
      end

      def filter_pattern(pattern)
        @filter_pattern = pattern.to_s
      end

      def pattern(p)
        filter_pattern(p)
      end

      def destination_type(type)
        @destination_type = type.to_sym
      end

      def type(t)
        destination_type(t)
      end

      def role_arn(role)
        @role_arn = role
      end

      def role(r)
        role_arn(r)
      end

      def distribution(dist)
        @distribution = dist.to_s
      end

      def build
        Model::SubscriptionFilter.new(
          destination: @destination,
          name: @name,
          filter_pattern: @filter_pattern,
          destination_type: @destination_type,
          role_arn: @role_arn,
          distribution: @distribution
        )
      end
    end

    # logs ブロック用 DSL ビルダー
    class LogsBuilder < BaseBuilder
      attr_reader :subscription_filters

      def initialize(retention_days: nil)
        super()
        @retention_days = retention_days
        @subscription_filters = []
      end

      def retention_days(days = nil)
        return @retention_days if days.nil?

        @retention_days = days.to_i
      end

      def retention_in_days(days)
        retention_days(days)
      end

      def subscription_filter(name_or_opts = nil, **kwargs, &)
        name = nil
        opts = {}

        if name_or_opts.is_a?(Hash)
          opts = name_or_opts.merge(kwargs)
        elsif name_or_opts.is_a?(Symbol) || name_or_opts.is_a?(String)
          name = name_or_opts.to_sym
          opts = kwargs
        else
          opts = kwargs
        end

        name ||= opts[:name]

        if block_given?
          builder = SubscriptionFilterBuilder.new(name)
          builder.instance_eval(&)
          @subscription_filters << builder.build
        else
          @subscription_filters << Model::SubscriptionFilter.new(
            destination: opts[:destination],
            name: name,
            filter_pattern: opts[:filter_pattern] || opts[:pattern] || '',
            destination_type: opts[:destination_type] || opts[:type] || :auto,
            role_arn: opts[:role_arn] || opts[:role],
            distribution: opts[:distribution]
          )
        end
      end

      def to_h
        res = {}
        res['retention_days'] = @retention_days if @retention_days
        res
      end
    end
  end
end
