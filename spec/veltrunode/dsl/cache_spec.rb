# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Cache DSL' do
  describe 'configuring remote s3 cache' do
    it 'supports cache: { remote: { s3: { bucket: "...", prefix: "..." } } } via method args' do
      app = Veltrunode.application 'sample-app' do
        cache remote: { s3: { bucket: 'my-cache-bucket', prefix: 'build-cache' } }
      end

      expect(app.cache_config).to eq(
        'remote' => {
          's3' => {
            'bucket' => 'my-cache-bucket',
            'prefix' => 'build-cache'
          }
        }
      )
      expect(app.cache).to eq(app.cache_config)
    end

    it 'supports cache DSL with block syntax' do
      app = Veltrunode.application 'sample-app' do
        cache do
          remote do
            s3 bucket: 'my-cache-bucket', prefix: 'ci-cache'
          end
        end
      end

      expect(app.cache_config).to eq(
        'remote' => {
          's3' => {
            'bucket' => 'my-cache-bucket',
            'prefix' => 'ci-cache'
          }
        }
      )
    end

    it 'supports cache option passed to Veltrunode.application keyword argument' do
      app = Veltrunode.application(
        'sample-app',
        cache: { remote: { s3: { bucket: 'kw-bucket', prefix: 'kw-prefix' } } }
      ) do
        runtime ruby: '3.3'
      end

      expect(app.cache_config).to eq(
        'remote' => {
          's3' => {
            'bucket' => 'kw-bucket',
            'prefix' => 'kw-prefix'
          }
        }
      )
    end
  end
end
