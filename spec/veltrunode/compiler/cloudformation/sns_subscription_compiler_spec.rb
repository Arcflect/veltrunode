# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/sns_subscription_compiler'
require 'veltrunode/model/function'
require 'veltrunode/model/event_source'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Compiler::CloudFormation::SnsSubscriptionCompiler do
  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'notifier',
      handler: 'notifier.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.compile' do
    it 'compiles AWS::SNS::Subscription and AWS::Lambda::Permission with literal topic ARN' do
      source = Veltrunode::Model::EventSource.new(
        type: :sns,
        topic: 'arn:aws:sns:ap-northeast-1:123456789012:order-events'
      )

      res = described_class.compile(function, source)

      expect(res).to eq(
        'NotifierFunctionOrderEventsSnsPermission' => {
          'Type' => 'AWS::Lambda::Permission',
          'Properties' => {
            'Action' => 'lambda:InvokeFunction',
            'FunctionName' => { 'Fn::GetAtt' => %w[NotifierFunction Arn] },
            'Principal' => 'sns.amazonaws.com',
            'SourceArn' => 'arn:aws:sns:ap-northeast-1:123456789012:order-events'
          }
        },
        'NotifierFunctionOrderEventsSnsSubscription' => {
          'Type' => 'AWS::SNS::Subscription',
          'Properties' => {
            'Endpoint' => { 'Fn::GetAtt' => %w[NotifierFunction Arn] },
            'Protocol' => 'lambda',
            'TopicArn' => 'arn:aws:sns:ap-northeast-1:123456789012:order-events'
          }
        }
      )
    end

    it 'compiles SNS subscription with ref(:topic) and FilterPolicy' do
      source = Veltrunode::Model::EventSource.new(
        type: :sns,
        topic: Veltrunode::DSL::Reference.new(:order_topic),
        filter_policy: {
          event_type: %w[order_created order_cancelled],
          amount: [{ numeric: ['>=', 1000] }]
        },
        filter_policy_scope: 'MessageAttributes'
      )

      res = described_class.compile(function, source)

      expect(res).to eq(
        'NotifierFunctionOrderTopicSnsPermission' => {
          'Type' => 'AWS::Lambda::Permission',
          'Properties' => {
            'Action' => 'lambda:InvokeFunction',
            'FunctionName' => { 'Fn::GetAtt' => %w[NotifierFunction Arn] },
            'Principal' => 'sns.amazonaws.com',
            'SourceArn' => { 'Ref' => 'OrderTopic' }
          }
        },
        'NotifierFunctionOrderTopicSnsSubscription' => {
          'Type' => 'AWS::SNS::Subscription',
          'Properties' => {
            'Endpoint' => { 'Fn::GetAtt' => %w[NotifierFunction Arn] },
            'FilterPolicy' => {
              'amount' => [{ 'numeric' => ['>=', 1000] }],
              'event_type' => %w[order_created order_cancelled]
            },
            'FilterPolicyScope' => 'MessageAttributes',
            'Protocol' => 'lambda',
            'TopicArn' => { 'Ref' => 'OrderTopic' }
          }
        }
      )
    end

    it 'compiles SNS subscription with symbolic topic name' do
      source = Veltrunode::Model::EventSource.new(
        sns: :system_alerts,
        filter_policy: { severity: ['high'] }
      )

      res = described_class.compile(function, source)

      sub = res['NotifierFunctionSystemAlertsSnsSubscription']
      perm = res['NotifierFunctionSystemAlertsSnsPermission']

      expect(sub['Properties']['TopicArn']).to eq('Ref' => 'SystemAlerts')
      expect(sub['Properties']['FilterPolicy']).to eq('severity' => ['high'])
      expect(perm['Properties']['SourceArn']).to eq('Ref' => 'SystemAlerts')
    end
  end

  describe '.to_yaml' do
    it 'produces valid YAML string containing Subscription and Permission' do
      source = Veltrunode::Model::EventSource.new(
        sns: 'arn:aws:sns:ap-northeast-1:123456789012:order-events',
        filter_policy: { status: ['paid'] }
      )

      yaml_str = described_class.to_yaml(function, source)
      parsed = YAML.safe_load(yaml_str)

      expect(parsed).to have_key('NotifierFunctionOrderEventsSnsSubscription')
      expect(parsed).to have_key('NotifierFunctionOrderEventsSnsPermission')
      expect(parsed['NotifierFunctionOrderEventsSnsSubscription']['Properties']['FilterPolicy']).to eq(
        'status' => ['paid']
      )
    end
  end
end
