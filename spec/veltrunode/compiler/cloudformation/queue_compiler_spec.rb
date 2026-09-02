# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/queue_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::QueueCompiler do
  describe '.logical_id_for' do
    it 'generates stable PascalCase logical IDs for SQS Queues' do
      expect(described_class.logical_id_for('batch_dlq')).to eq('BatchDlqQueue')
      expect(described_class.logical_id_for('batch_dlq_queue')).to eq('BatchDlqQueue')
      expect(described_class.logical_id_for('orders_queue')).to eq('OrdersQueue')
      expect(described_class.logical_id_for('')).to eq('Queue')
    end
  end

  describe '#to_h and properties' do
    it 'compiles a minimal queue resource without properties' do
      result = described_class.compile('batch_dlq')

      expect(result).to have_key('BatchDlqQueue')
      resource = result['BatchDlqQueue']
      expect(resource['Type']).to eq('AWS::SQS::Queue')
      expect(resource).not_to have_key('Properties')
    end

    it 'compiles a queue with options (MessageRetentionPeriod, VisibilityTimeout, KmsMasterKeyId)' do
      result = described_class.compile(
        'event_dlq',
        options: {
          message_retention_period: 1_209_600,
          visibility_timeout: 300,
          kms_master_key_id: 'alias/aws/sqs'
        }
      )

      props = result['EventDlqQueue']['Properties']
      expect(props['MessageRetentionPeriod']).to eq(1_209_600)
      expect(props['VisibilityTimeout']).to eq(300)
      expect(props['KmsMasterKeyId']).to eq('alias/aws/sqs')
    end

    it 'allows explicit QueueName when explicit_name option is enabled' do
      result = described_class.compile(
        'custom_named_dlq',
        options: { explicit_name: true }
      )

      props = result['CustomNamedDlqQueue']['Properties']
      expect(props['QueueName']).to eq('custom_named_dlq')
    end
  end

  describe 'Determinism & Key Sorting' do
    it 'guarantees keys in to_h map are sorted alphabetically' do
      result = described_class.compile(
        'full_queue',
        options: {
          explicit_name: true,
          message_retention_period: 86_400,
          visibility_timeout: 60,
          kms_master_key_id: 'alias/my-key'
        }
      )

      resource_keys = result['FullQueue'].keys
      expect(resource_keys).to eq(resource_keys.sort)

      prop_keys = result['FullQueue']['Properties'].keys
      expect(prop_keys).to eq(prop_keys.sort)
    end

    it 'produces deterministic YAML output across multiple compilations' do
      yaml1 = described_class.to_yaml(
        'event_queue',
        options: { message_retention_period: 86_400, visibility_timeout: 60 }
      )
      yaml2 = described_class.to_yaml(
        'event_queue',
        options: { message_retention_period: 86_400, visibility_timeout: 60 }
      )

      expect(yaml1).to eq(yaml2)
    end
  end

  describe 'Golden Test Comparison' do
    it 'matches expected golden YAML output for standard SQS queue' do
      expected_yaml = <<~YAML
        ---
        BatchDlqQueue:
          Properties:
            KmsMasterKeyId: alias/aws/sqs
            MessageRetentionPeriod: 1209600
            VisibilityTimeout: 300
          Type: AWS::SQS::Queue
      YAML

      generated_yaml = described_class.to_yaml(
        'batch_dlq',
        options: {
          message_retention_period: 1_209_600,
          visibility_timeout: 300,
          kms_master_key_id: 'alias/aws/sqs'
        }
      )

      expect(YAML.safe_load(generated_yaml)).to eq(YAML.safe_load(expected_yaml))
      expect(generated_yaml.strip).to eq(expected_yaml.strip)
    end
  end
end
