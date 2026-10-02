# frozen_string_literal: true

require 'json'
require 'base64'

def handler(event:, context:)
  encoded = Base64.strict_encode64('veltrunode-layer-test')
  {
    statusCode: 200,
    body: JSON.generate({
      encoded: encoded,
      decoded: Base64.decode64(encoded),
      event: event
    })
  }
end
