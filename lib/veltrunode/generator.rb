# frozen_string_literal: true

require 'fileutils'

module Veltrunode
  class Generator
    def self.run(target_dir = '.')
      generator = new(target_dir)
      generator.generate_all
    end

    def initialize(target_dir)
      @target_dir = target_dir
    end

    def generate_all
      create_directory('functions')
      create_directory('tests')
      create_directory('.github/workflows')

      write_file('Veltrunodefile', veltrunodefile_template)
      write_file('functions/hello.rb', ruby_handler_template)
      write_file('functions/hello.py', python_handler_template)
      write_file('functions/hello.js', node_handler_template)
      write_file('tests/hello_test.rb', test_template)
      write_file('.github/workflows/deploy.yml', ci_template)

      puts 'Project initialized successfully!'
    end

    private

    def create_directory(path)
      full_path = File.join(@target_dir, path)
      FileUtils.mkdir_p(full_path)
    end

    def write_file(filename, content)
      full_path = File.join(@target_dir, filename)
      if File.exist?(full_path)
        puts "Skipped: #{filename} (already exists)"
      else
        File.write(full_path, content)
        puts "Created: #{filename}"
      end
    end

    def veltrunodefile_template
      <<~RUBY
        Veltrunode.application "my-veltrunode-app" do
          aws region: "ap-northeast-1"
          runtime ruby: "3.4", architecture: :arm64

          defaults do
            logs retention_days: 14
          end

          # Example Function (Ruby)
          function :hello do
            handler "functions/hello.handler"
            memory 512
            timeout 30
          end

          # Example Scheduler
          schedule :daily do
            target :hello
            cron "0 9 * * ? *", timezone: "Asia/Tokyo"
          end
        end
      RUBY
    end

    def ruby_handler_template
      <<~RUBY
        def handler(event:, context:)
          puts "Hello from Ruby Lambda!"
          { statusCode: 200, body: "Hello World" }
        end
      RUBY
    end

    def python_handler_template
      <<~PYTHON
        def handler(event, context):
            print("Hello from Python Lambda!")
            return {
                "statusCode": 200,
                "body": "Hello World"
            }
      PYTHON
    end

    def node_handler_template
      <<~JS
        exports.handler = async (event, context) => {
            console.log("Hello from Node.js Lambda!");
            return {
                statusCode: 200,
                body: "Hello World"
            };
        };
      JS
    end

    def test_template
      <<~RUBY
        # Sample test for your handler
        require "rspec"
        require_relative "../functions/hello"

        RSpec.describe "Hello Handler" do
          it "returns status 200" do
            response = handler(event: {}, context: {})
            expect(response[:statusCode]).to eq(200)
          end
        end
      RUBY
    end

    def ci_template
      <<~YAML
        name: Deploy

        on:
          push:
            branches: [ main ]

        jobs:
          deploy:
            runs-on: ubuntu-latest
            steps:
            - uses: actions/checkout@v3
            - name: Set up Ruby
              uses: ruby/setup-ruby@v1
              with:
                ruby-version: '3.4'
                bundler-cache: true
            - name: Configure AWS Credentials
              uses: aws-actions/configure-aws-credentials@v2
              with:
                aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
                aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
                aws-region: ap-northeast-1
            - name: Validate
              run: bundle exec veltrunode validate
            - name: Deploy
              run: bundle exec veltrunode deploy
      YAML
    end
  end
end
