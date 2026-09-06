# frozen_string_literal: true

require 'fileutils'

module Veltrunode
  class Generator
    Result = Struct.new(:created_files, :skipped_files, :target_dir, keyword_init: true)

    DEFAULT_RUNTIME = 'ruby'
    DEFAULT_REGION = 'ap-northeast-1'

    class << self
      def run(target_dir = '.', runtime: DEFAULT_RUNTIME, app_name: nil)
        new(target_dir, runtime: runtime, app_name: app_name).generate
      end
    end

    attr_reader :target_dir, :runtime, :app_name

    def initialize(target_dir = '.', runtime: DEFAULT_RUNTIME, app_name: nil)
      @target_dir = File.expand_path(target_dir.to_s)
      @runtime = (runtime || DEFAULT_RUNTIME).to_s.strip.downcase
      @app_name = normalize_app_name(app_name || File.basename(@target_dir))
    end

    def generate
      created_files = []
      skipped_files = []

      templates.each do |rel_path, content|
        dest_path = File.join(@target_dir, rel_path)
        if File.exist?(dest_path)
          skipped_files << rel_path
        else
          FileUtils.mkdir_p(File.dirname(dest_path))
          File.write(dest_path, content)
          created_files << rel_path
        end
      end

      Result.new(
        created_files: created_files,
        skipped_files: skipped_files,
        target_dir: @target_dir
      )
    end

    private

    def normalize_app_name(raw_name)
      name = raw_name.to_s.strip
      name = 'my_veltrunode_app' if name.empty? || name == '.'
      name.gsub(/[^a-zA-Z0-9_-]/, '_')
    end

    def runtime_type
      if @runtime.start_with?('python')
        :python
      elsif @runtime.start_with?('node', 'js')
        :nodejs
      else
        :ruby
      end
    end

    def templates
      files = {
        'Veltrunodefile' => veltrunodefile_content,
        'Gemfile' => gemfile_content,
        '.gitignore' => gitignore_content,
        '.github/workflows/ci.yml' => ci_workflow_content,
        'spec/spec_helper.rb' => spec_helper_content
      }

      case runtime_type
      when :python
        files['functions/app.py'] = python_handler_content
        files['spec/functions/app_spec.rb'] = python_spec_content
      when :nodejs
        files['functions/app.js'] = nodejs_handler_content
        files['spec/functions/app_spec.rb'] = nodejs_spec_content
      else
        files['functions/app.rb'] = ruby_handler_content
        files['spec/functions/app_spec.rb'] = ruby_spec_content
      end

      files
    end

    def veltrunodefile_content
      case runtime_type
      when :python
        py_ver = @runtime.match?(/3\.\d+/) ? @runtime : 'python3.12'
        <<~RUBY
          # frozen_string_literal: true

          Veltrunode.application '#{@app_name}' do
            aws region: '#{DEFAULT_REGION}'

            defaults do
              logs retention_days: 14
            end

            function :app do
              handler 'functions/app.handler'
              runtime '#{py_ver}'
              memory 512
              timeout 30
            end
          end
        RUBY
      when :nodejs
        node_ver = @runtime.match?(/\d+/) ? @runtime : 'nodejs20.x'
        <<~RUBY
          # frozen_string_literal: true

          Veltrunode.application '#{@app_name}' do
            aws region: '#{DEFAULT_REGION}'

            defaults do
              logs retention_days: 14
            end

            function :app do
              handler 'functions/app.handler'
              runtime '#{node_ver}'
              memory 512
              timeout 30
            end
          end
        RUBY
      else
        <<~RUBY
          # frozen_string_literal: true

          Veltrunode.application '#{@app_name}' do
            aws region: '#{DEFAULT_REGION}'
            runtime ruby: '3.3', architecture: :x86_64

            defaults do
              logs retention_days: 14
            end

            function :app do
              handler 'functions/app.handler'
              memory 512
              timeout 30
            end
          end
        RUBY
      end
    end

    def ruby_handler_content
      <<~RUBY
        # frozen_string_literal: true

        def handler(event:, context:)
          {
            statusCode: 200,
            body: { message: 'Hello from Veltrunode!' }
          }
        end
      RUBY
    end

    def python_handler_content
      <<~PYTHON
        def handler(event, context):
            return {
                "statusCode": 200,
                "body": {"message": "Hello from Veltrunode!"}
            }
      PYTHON
    end

    def nodejs_handler_content
      <<~JS
        exports.handler = async (event, context) => {
            return {
                statusCode: 200,
                body: { message: "Hello from Veltrunode!" }
            };
        };
      JS
    end

    def gemfile_content
      <<~RUBY
        # frozen_string_literal: true

        source 'https://rubygems.org'

        gem 'veltrunode', '~> #{Veltrunode::VERSION}'

        group :development, :test do
          gem 'rspec', '~> 3.12'
          gem 'rubocop', '~> 1.60', require: false
        end
      RUBY
    end

    def spec_helper_content
      <<~RUBY
        # frozen_string_literal: true

        require 'rspec'

        RSpec.configure do |config|
          config.expect_with :rspec do |expectations|
            expectations.include_chain_clauses_in_custom_matcher_descriptions = true
          end
          config.mock_with :rspec do |mocks|
            mocks.verify_partial_doubles = true
          end
          config.disable_monkey_patching!
          config.warnings = true
          config.order = :random
          Kernel.srand config.seed
        end
      RUBY
    end

    def ruby_spec_content
      <<~RUBY
        # frozen_string_literal: true

        require 'spec_helper'
        require_relative '../../functions/app'

        RSpec.describe 'app function' do
          it 'returns a successful response' do
            response = handler(event: {}, context: {})
            expect(response[:statusCode]).to eq(200)
            expect(response[:body][:message]).to eq('Hello from Veltrunode!')
          end
        end
      RUBY
    end

    def python_spec_content
      <<~RUBY
        # frozen_string_literal: true

        require 'spec_helper'

        RSpec.describe 'app function handler' do
          it 'defines expected handler file' do
            expect(File.exist?(File.expand_path('../../functions/app.py', __dir__))).to be(true)
          end
        end
      RUBY
    end

    def nodejs_spec_content
      <<~RUBY
        # frozen_string_literal: true

        require 'spec_helper'

        RSpec.describe 'app function handler' do
          it 'defines expected handler file' do
            expect(File.expand_path('../../functions/app.js', __dir__)).to satisfy { |f| File.exist?(f) }
          end
        end
      RUBY
    end

    def ci_workflow_content
      <<~YAML
        name: CI

        on:
          push:
            branches: [main]
          pull_request:
            branches: [main]

        jobs:
          validate-and-test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: Set up Ruby
                uses: ruby/setup-ruby@v1
                with:
                  ruby-version: '3.3'
                  bundler-cache: true
              - name: Run RSpec
                run: bundle exec rspec
              - name: Validate Veltrunode Configuration
                run: bundle exec veltrunode validate
      YAML
    end

    def gitignore_content
      <<~GITIGNORE
        # Veltrunode build artifacts
        build/
        .veltrunode/

        # Ruby Bundler & Gem artifacts
        /.bundle/
        /vendor/bundle/
        Gemfile.lock

        # Test coverage & Temporary files
        /coverage/
        /tmp/
        *.log
        .DS_Store
      GITIGNORE
    end
  end
end
