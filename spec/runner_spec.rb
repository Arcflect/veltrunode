require "spec_helper"
require "tmpdir"

RSpec.describe Veltrunode::Runner do
  it "executes a Ruby handler method" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write("hello.rb", <<~RUBY)
          def handler(event:, context:)
            { status: 200, received: event[:val] }
          end
        RUBY

        func = Veltrunode::Function.new(:hello)
        func.handler = "hello.handler"
        func.runtime = "ruby3.2"

        res = Veltrunode::Runner.run(func, { val: "abc" })
        expect(res).to eq({ status: 200, received: "abc" })
      end
    end
  end
end
