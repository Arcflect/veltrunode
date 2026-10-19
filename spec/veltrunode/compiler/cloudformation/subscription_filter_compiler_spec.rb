# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model/function'
require 'veltrunode/model/subscription_filter'
require 'veltrunode/compiler/cloudformation/subscription_filter_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::SubscriptionFilterCompiler do
  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'api',
      handler: 'app.handler',
      runtime: 'nodejs20.x'
    )
  end

  describe '#compile with Lambda destination' do
    let(:filter) do
      Veltrunode::Model::SubscriptionFilter.new(
        destination: 'arn:aws:lambda:ap-northeast-1:123456789012:function:central-logger',
        filter_pattern: '[timestamp, request_id, level = ERROR*, ...]'
      )
    end

    it 'generates SubscriptionFilter and Lambda Permission resources' do
      res = described_class.compile(function, filter)

      expect(res).to have_key('ApiFunctionSubscriptionFilter')
      expect(res).to have_key('ApiFunctionLogsPermission')

      filter_res = res['ApiFunctionSubscriptionFilter']
      expect(filter_res['Type']).to eq('AWS::Logs::SubscriptionFilter')
      expect(filter_res['DependsOn']).to eq(%w[ApiFunctionLogGroup ApiFunctionLogsPermission])
      expect(filter_res['Properties']['DestinationArn']).to eq(
        'arn:aws:lambda:ap-northeast-1:123456789012:function:central-logger'
      )
      expect(filter_res['Properties']['FilterPattern']).to eq(
        '[timestamp, request_id, level = ERROR*, ...]'
      )
      expect(filter_res['Properties']['LogGroupName']).to eq({ 'Ref' => 'ApiFunctionLogGroup' })

      perm_res = res['ApiFunctionLogsPermission']
      expect(perm_res['Type']).to eq('AWS::Lambda::Permission')
      expect(perm_res['Properties']['Action']).to eq('lambda:InvokeFunction')
      expect(perm_res['Properties']['FunctionName']).to eq(
        'arn:aws:lambda:ap-northeast-1:123456789012:function:central-logger'
      )
      expect(perm_res['Properties']['Principal']).to eq({ 'Fn::Sub' => 'logs.${AWS::Region}.amazonaws.com' })
      expect(perm_res['Properties']['SourceArn']).to eq({ 'Fn::GetAtt' => %w[ApiFunctionLogGroup Arn] })
    end
  end

  describe '#compile with Kinesis destination and auto-generated role' do
    let(:filter) do
      Veltrunode::Model::SubscriptionFilter.new(
        name: 'kinesis_stream',
        destination: 'arn:aws:kinesis:ap-northeast-1:123456789012:stream/app-logs',
        filter_pattern: '',
        distribution: 'ByLogStream'
      )
    end

    it 'generates SubscriptionFilter and IAM Role resources' do
      res = described_class.compile(function, filter)

      expect(res).to have_key('ApiFunctionKinesisStreamSubscriptionFilter')
      expect(res).to have_key('ApiFunctionKinesisStreamLogsRole')

      filter_res = res['ApiFunctionKinesisStreamSubscriptionFilter']
      expect(filter_res['Type']).to eq('AWS::Logs::SubscriptionFilter')
      expect(filter_res['DependsOn']).to eq(%w[ApiFunctionKinesisStreamLogsRole ApiFunctionLogGroup])
      expect(filter_res['Properties']['RoleArn']).to eq({ 'Fn::GetAtt' => %w[ApiFunctionKinesisStreamLogsRole Arn] })
      expect(filter_res['Properties']['Distribution']).to eq('ByLogStream')

      role_res = res['ApiFunctionKinesisStreamLogsRole']
      expect(role_res['Type']).to eq('AWS::IAM::Role')
      assume_doc = role_res['Properties']['AssumeRolePolicyDocument']
      expect(assume_doc['Statement'].first['Principal']['Service']).to eq(
        { 'Fn::Sub' => 'logs.${AWS::Region}.amazonaws.com' }
      )
      policy = role_res['Properties']['Policies'].first
      expect(policy['PolicyDocument']['Statement'].first['Action']).to eq(
        %w[kinesis:PutRecord kinesis:PutRecords]
      )
    end
  end

  describe '#compile with Firehose destination and custom role_arn' do
    let(:filter) do
      Veltrunode::Model::SubscriptionFilter.new(
        destination: 'arn:aws:firehose:ap-northeast-1:123456789012:deliverystream/app-firehose',
        role_arn: 'arn:aws:iam::123456789012:role/MyExistingLogsRole'
      )
    end

    it 'uses existing role_arn without generating a new IAM role' do
      res = described_class.compile(function, filter)

      expect(res).to have_key('ApiFunctionSubscriptionFilter')
      expect(res).not_to have_key('ApiFunctionLogsRole')

      filter_res = res['ApiFunctionSubscriptionFilter']
      expect(filter_res['Properties']['RoleArn']).to eq('arn:aws:iam::123456789012:role/MyExistingLogsRole')
      expect(filter_res['DependsOn']).to eq(%w[ApiFunctionLogGroup])
    end
  end
end
