# frozen_string_literal: true

require 'bundler/setup'

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

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    FileUtils.rm_rf(File.join(Dir.pwd, '.veltrunode', 'cache'))
  end

  config.after do
    FileUtils.rm_rf(File.join(Dir.pwd, '.veltrunode', 'cache'))
  end
end
