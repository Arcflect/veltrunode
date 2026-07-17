# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::DSL do
  it 'correctly parses application and functions' do
    app = Veltrunode::DSL.evaluate 'test-app' do
      aws region: 'ap-northeast-1', account: '123456789012'
      runtime ruby: '3.4', architecture: :arm64

      function :hello do
        handler 'functions/hello.handler'
        memory 512
        timeout 30
      end
    end

    expect(app.name).to eq('test-app')
    expect(app.region).to eq('ap-northeast-1')
    expect(app.account).to eq('123456789012')
    expect(app.runtime).to eq('ruby3.4')
    expect(app.architecture).to eq(:arm64)

    expect(app.functions[:hello]).not_to be_nil
    expect(app.functions[:hello].handler).to eq('functions/hello.handler')
    expect(app.functions[:hello].memory).to eq(512)
    expect(app.functions[:hello].timeout).to eq(30)
  end
end
