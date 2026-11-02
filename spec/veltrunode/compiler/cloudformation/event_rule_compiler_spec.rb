# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/dsl'
require 'veltrunode/model/function'
require 'veltrunode/model/event_source'
require 'veltrunode/compiler/cloudformation/event_rule_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::EventRuleCompiler do
  let(:function) do
    Veltrunode::Model::Function.new(
      'order_handler',
      handler: 'orders.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.compile' do
    it 'generates AWS::Events::Rule and AWS::Lambda::Permission for custom event bus and pattern' do
      source = Veltrunode::Model::EventSource.new(
        rule: {
          bus: 'custom-orders-bus',
          pattern: {
            source: ['myapp.orders'],
            'detail-type': %w[OrderCreated OrderCompleted]
          }
        }
      )

      resources = described_class.compile(function, source)

      expect(resources).to have_key('OrderHandlerFunctionCustomOrdersBusEventRule')
      expect(resources).to have_key('OrderHandlerFunctionCustomOrdersBusEventsPermission')

      rule = resources['OrderHandlerFunctionCustomOrdersBusEventRule']
      expect(rule['Type']).to eq('AWS::Events::Rule')
      expect(rule['Properties']).to eq(
        'EventBusName' => 'custom-orders-bus',
        'EventPattern' => {
          'detail-type' => %w[OrderCreated OrderCompleted],
          'source' => ['myapp.orders']
        },
        'State' => 'ENABLED',
        'Targets' => [
          {
            'Arn' => { 'Fn::GetAtt' => %w[OrderHandlerFunction Arn] },
            'Id' => 'OrderHandlerFunctionTarget'
          }
        ]
      )

      perm = resources['OrderHandlerFunctionCustomOrdersBusEventsPermission']
      expect(perm['Type']).to eq('AWS::Lambda::Permission')
      expect(perm['Properties']).to eq(
        'Action' => 'lambda:InvokeFunction',
        'FunctionName' => { 'Fn::GetAtt' => %w[OrderHandlerFunction Arn] },
        'Principal' => 'events.amazonaws.com',
        'SourceArn' => {
          'Fn::GetAtt' => %w[OrderHandlerFunctionCustomOrdersBusEventRule Arn]
        }
      )
    end

    it 'supports state: :disabled and referenced event bus via ref(:domain_bus)' do
      ref_bus = Veltrunode::DSL::Reference.new(:domain_bus)
      source = Veltrunode::Model::EventSource.new(
        rule: {
          name: :invoice_rule,
          bus: ref_bus,
          pattern: {
            source: ['myapp.billing'],
            'detail-type': ['InvoiceIssued'],
            detail: { status: ['OVERDUE'] }
          },
          state: :disabled,
          description: 'Disabled rule for overdue invoices'
        }
      )

      resources = described_class.compile(function, source)

      rule = resources['OrderHandlerFunctionInvoiceEventRule']
      expect(rule['Type']).to eq('AWS::Events::Rule')
      expect(rule['Properties']['EventBusName']).to eq('Ref' => 'DomainBus')
      expect(rule['Properties']['State']).to eq('DISABLED')
      expect(rule['Properties']['Description']).to eq('Disabled rule for overdue invoices')
      expect(rule['Properties']['EventPattern']).to eq(
        'detail' => { 'status' => ['OVERDUE'] },
        'detail-type' => ['InvoiceIssued'],
        'source' => ['myapp.billing']
      )

      perm = resources['OrderHandlerFunctionInvoiceEventsPermission']
      expect(perm['Properties']['SourceArn']).to eq(
        'Fn::GetAtt' => %w[OrderHandlerFunctionInvoiceEventRule Arn]
      )
    end

    it 'omits EventBusName when bus is not specified (default event bus)' do
      source = Veltrunode::Model::EventSource.new(
        rule: {
          pattern: {
            source: ['aws.ec2'],
            'detail-type': ['EC2 Instance State-change Notification']
          }
        }
      )

      resources = described_class.compile(function, source)

      rule = resources['OrderHandlerFunctionEventRule']
      expect(rule['Properties']).not_to have_key('EventBusName')
      expect(rule['Properties']['State']).to eq('ENABLED')
    end
  end
end
