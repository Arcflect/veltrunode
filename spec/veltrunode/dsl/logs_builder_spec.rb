# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl/function_builder'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::DSL::LogsBuilder do
  describe 'DSL evaluation in FunctionBuilder' do
    it 'builds subscription filter with block syntax' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:api)
      builder.logs do
        retention_days 14
        subscription_filter destination: 'arn:aws:lambda:ap-northeast-1:123456789012:function:central-logger',
                            filter_pattern: '[timestamp, request_id, level = ERROR*, ...]'
      end

      fn = builder.build
      expect(fn.subscription_filters.size).to eq(1)

      filter = fn.subscription_filters.first
      expect(filter.destination).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:central-logger')
      expect(filter.filter_pattern).to eq('[timestamp, request_id, level = ERROR*, ...]')
      expect(filter.name).to be_nil
    end

    it 'builds multiple named subscription filters' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:worker)
      builder.logs do
        subscription_filter :opensearch,
                            destination: 'arn:aws:firehose:ap-northeast-1:123456789012:deliverystream/os-stream',
                            filter_pattern: '{ $.level = "WARN" || $.level = "ERROR" }'
        subscription_filter :s3_archive,
                            destination: 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/archive-stream',
                            filter_pattern: '',
                            distribution: 'ByLogStream'
      end

      fn = builder.build
      expect(fn.subscription_filters.size).to eq(2)

      os_filter = fn.subscription_filters.find { |f| f.name == :opensearch }
      expect(os_filter).not_to be_nil
      expect(os_filter.destination).to eq('arn:aws:firehose:ap-northeast-1:123456789012:deliverystream/os-stream')
      expect(os_filter.filter_pattern).to eq('{ $.level = "WARN" || $.level = "ERROR" }')

      archive_filter = fn.subscription_filters.find { |f| f.name == :s3_archive }
      expect(archive_filter).not_to be_nil
      expect(archive_filter.destination).to eq('arn:aws:kinesis:ap-northeast-1:123456789012:stream/archive-stream')
      expect(archive_filter.distribution).to eq('ByLogStream')
    end

    it 'supports nested block syntax for subscription_filter' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:processor)
      builder.logs do
        subscription_filter :datadog do
          destination 'arn:aws:lambda:ap-northeast-1:123456789012:function:datadog-forwarder'
          filter_pattern '[msg]'
        end
      end

      fn = builder.build
      expect(fn.subscription_filters.size).to eq(1)
      filter = fn.subscription_filters.first
      expect(filter.name).to eq(:datadog)
      expect(filter.destination).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:datadog-forwarder')
      expect(filter.filter_pattern).to eq('[msg]')
    end

    it 'supports hash argument syntax on logs method' do
      builder = Veltrunode::DSL::FunctionBuilder.new(:api)
      builder.logs(
        retention_days: 30,
        subscription_filter: {
          destination: 'arn:aws:lambda:ap-northeast-1:123456789012:function:log-forwarder',
          filter_pattern: 'ERROR'
        }
      )

      fn = builder.build
      expect(fn.subscription_filters.size).to eq(1)
      filter = fn.subscription_filters.first
      expect(filter.destination).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:log-forwarder')
      expect(filter.filter_pattern).to eq('ERROR')
    end
  end
end
