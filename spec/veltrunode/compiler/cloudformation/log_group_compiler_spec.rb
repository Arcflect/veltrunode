# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe Veltrunode::Compiler::CloudFormation::LogGroupCompiler do
  let(:minimal_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'convert',
      handler: 'convert.handler',
      runtime: 'ruby3.3'
    )
  end

  let(:full_function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api_handler',
      handler: 'functions/api.handler',
      runtime: 'ruby3.3',
      logging: { retention_days: 14 }
    )
  end

  describe '.logical_id_for' do
    it 'converts function symbolic and logical names to stable LogGroup Logical IDs' do
      expect(described_class.logical_id_for(:convert)).to eq('ConvertFunctionLogGroup')
      expect(described_class.logical_id_for('convert')).to eq('ConvertFunctionLogGroup')
      expect(described_class.logical_id_for('api_handler')).to eq('ApiHandlerFunctionLogGroup')
      expect(described_class.logical_id_for('ConvertFunction')).to eq('ConvertFunctionLogGroup')
      expect(described_class.logical_id_for('ConvertFunctionLogGroup')).to eq('ConvertFunctionLogGroup')
    end
  end

  describe '#to_h and #properties' do
    it 'compiles a LogGroup resource for minimal function with default retention_days (30)' do
      result = described_class.compile(minimal_function)

      expect(result).to have_key('ConvertFunctionLogGroup')

      resource = result['ConvertFunctionLogGroup']
      expect(resource['Type']).to eq('AWS::Logs::LogGroup')

      props = resource['Properties']
      expect(props['LogGroupName']).to eq('/aws/lambda/convert')
      expect(props['RetentionInDays']).to eq(30)
    end

    it 'respects retention_days configured on the Function model' do
      result = described_class.compile(full_function)
      props = result['ApiHandlerFunctionLogGroup']['Properties']

      expect(props['LogGroupName']).to eq('/aws/lambda/api_handler')
      expect(props['RetentionInDays']).to eq(14)
    end

    it 'respects retention_days passed in defaults parameter' do
      defaults = { logs: { retention_days: 7 } }
      result = described_class.compile(minimal_function, defaults: defaults)
      props = result['ConvertFunctionLogGroup']['Properties']

      expect(props['RetentionInDays']).to eq(7)
    end

    it 'prioritizes explicit retention_days parameter over defaults and function config' do
      result = described_class.compile(full_function, retention_days: 60)
      props = result['ApiHandlerFunctionLogGroup']['Properties']

      expect(props['RetentionInDays']).to eq(60)
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(full_function)
      resource_keys = result['ApiHandlerFunctionLogGroup'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['ApiHandlerFunctionLogGroup']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)
    end

    it 'produces deterministic YAML output across multiple compilations' do
      yaml1 = described_class.to_yaml(full_function)
      yaml2 = described_class.to_yaml(full_function)

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches the expected golden YAML output for LogGroup' do
      expected_yaml = <<~YAML
        ---
        ApiHandlerFunctionLogGroup:
          Properties:
            LogGroupName: "/aws/lambda/api_handler"
            RetentionInDays: 14
          Type: AWS::Logs::LogGroup
      YAML

      generated_yaml = described_class.to_yaml(full_function)
      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
