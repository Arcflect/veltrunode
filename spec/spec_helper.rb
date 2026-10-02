# frozen_string_literal: true

require 'bundler/setup'
require 'rspec'

require 'ostruct'
require 'simplecov'

SimpleCov.start do
  if respond_to?(:skip)
    skip '/spec/'
  else
    add_filter '/spec/'
  end
end

require 'veltrunode'
require_relative 'support/integration_helper'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # デフォルトでは統合テスト（--tag integration）を除外
  config.filter_run_excluding :integration unless config.inclusion_filter[:integration]

  config.before do
    FileUtils.rm_rf(File.join(Dir.pwd, '.veltrunode', 'cache'))
    FileUtils.rm_rf(File.join(Dir.pwd, 'build'))
  end

  config.after do
    FileUtils.rm_rf(File.join(Dir.pwd, '.veltrunode', 'cache'))
    FileUtils.rm_rf(File.join(Dir.pwd, 'build'))
  end
end
