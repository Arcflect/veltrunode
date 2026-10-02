# frozen_string_literal: true

require 'json'
require 'time'

def handler(event:, context:)
  puts "Executed by one-time schedule: #{event.inspect}"
  {
    statusCode: 200,
    body: JSON.generate({
      status: 'ok',
      message: 'Triggered by one-time schedule',
      event: event,
      timestamp: Time.now.utc.iso8601
    })
  }
end
