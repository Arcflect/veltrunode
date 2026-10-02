# frozen_string_literal: true

require 'json'
require 'rainbow'

def handler(event:, context:)
  colored = Rainbow('Veltrunode Layer Integration Test').green.bright
  {
    statusCode: 200,
    body: JSON.generate({
      message: colored.to_s,
      event: event
    })
  }
end
