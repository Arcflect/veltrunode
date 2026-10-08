# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/build/layer_package_result'

RSpec.describe Veltrunode::Build::LayerPackageResult do
  subject(:result) do
    described_class.new(
      layer_name: 'test_layer',
      zip_path: '/tmp/test.zip',
      content_hash: 'abc123hash',
      sha256: 'sha256abc',
      compressed_size: 1024,
      uncompressed_size: 2048,
      size_diagnostics: { 'largest_entries' => [] },
      entries: ['file1.rb'],
      reused: true,
      layer_version_arn: 'arn:aws:lambda:ap-northeast-1:123456789012:layer:test_layer:1'
    )
  end

  it 'exposes layer attributes and reuse status' do
    expect(result.layer_name).to eq('test_layer')
    expect(result.content_hash).to eq('abc123hash')
    expect(result.sha256).to eq('sha256abc')
    expect(result.reused?).to be true
    expect(result.layer_version_arn).to eq('arn:aws:lambda:ap-northeast-1:123456789012:layer:test_layer:1')
  end

  it 'defaults reused to false' do
    default_res = described_class.new(
      layer_name: 'test_layer',
      zip_path: '/tmp/test.zip',
      content_hash: 'abc123hash',
      sha256: 'sha256abc',
      compressed_size: 1024,
      uncompressed_size: 2048,
      size_diagnostics: {},
      entries: []
    )
    expect(default_res.reused?).to be false
    expect(default_res.layer_version_arn).to be_nil
  end
end
