# frozen_string_literal: true

require 'json'
require 'time'

def handler(event:, context:)
  {
    statusCode: 200,
    body: JSON.generate({
      message: 'Hello from Veltrunode minimal integration worker!',
      event: event,
      time: Time.now.utc.iso8601
    })
  }
end
