# frozen_string_literal: true

require 'bundler/setup'

require 'simplecov'

SimpleCov.start do
  add_filter '/spec/'
end

require 'veltrunode'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
