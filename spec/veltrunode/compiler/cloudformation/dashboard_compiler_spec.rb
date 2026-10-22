# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'veltrunode/model/dashboard'
require 'veltrunode/model/function'
require 'veltrunode/compiler/cloudformation/dashboard_compiler'

RSpec.describe Veltrunode::Compiler::CloudFormation::DashboardCompiler do
  let(:fn1) { instance_double(Veltrunode::Model::Function, logical_name: 'convert') }
  let(:fn2) { instance_double(Veltrunode::Model::Function, logical_name: 'process') }
  let(:functions) { [fn1, fn2] }

  describe '.compile' do
    context 'with default dashboard' do
      let(:dashboard) { Veltrunode::Model::Dashboard.new }

      it 'generates AWS::CloudWatch::Dashboard resource' do
        compiled = described_class.compile(dashboard, functions: functions)

        expect(compiled).to have_key('Dashboard')
        resource = compiled['Dashboard']
        expect(resource['Type']).to eq('AWS::CloudWatch::Dashboard')

        props = resource['Properties']
        expect(props['DashboardName']).to eq({ 'Fn::Sub' => '${AWS::StackName}-Dashboard' })

        sub_body = props['DashboardBody']
        expect(sub_body).to have_key('Fn::Sub')

        body_json = sub_body['Fn::Sub']
        body = JSON.parse(body_json)

        expect(body).to have_key('widgets')
        widgets = body['widgets']
        expect(widgets.size).to eq(4)

        invocations = widgets.find { |w| w['properties']['title'] == 'Invocations' }
        expect(invocations).not_to be_nil
        expect(invocations['type']).to eq('metric')
        expect(invocations['properties']['stat']).to eq('Sum')
        expect(invocations['properties']['period']).to eq(300)
        expect(invocations['properties']['region']).to eq('${AWS::Region}')
        expect(invocations['properties']['metrics']).to eq([
                                                             ['AWS/Lambda', 'Invocations', 'FunctionName',
                                                              '${ConvertFunction}'],
                                                             ['AWS/Lambda', 'Invocations', 'FunctionName',
                                                              '${ProcessFunction}']
                                                           ])

        errors = widgets.find { |w| w['properties']['title'] == 'Errors' }
        expect(errors).not_to be_nil
        expect(errors['properties']['stat']).to eq('Sum')
        expect(errors['properties']['metrics']).to eq([
                                                        ['AWS/Lambda', 'Errors', 'FunctionName', '${ConvertFunction}'],
                                                        ['AWS/Lambda', 'Errors', 'FunctionName', '${ProcessFunction}']
                                                      ])

        duration = widgets.find { |w| w['properties']['title'] == 'Duration' }
        expect(duration).not_to be_nil
        expect(duration['properties']['stat']).to eq('Average')

        concurrency = widgets.find { |w| w['properties']['title'] == 'Concurrent Executions' }
        expect(concurrency).not_to be_nil
        expect(concurrency['properties']['stat']).to eq('Maximum')
      end
    end

    context 'with custom dashboard name and widgets' do
      let(:dashboard) do
        Veltrunode::Model::Dashboard.new(
          name: :ops,
          title: 'Operations Dashboard',
          period: 60,
          widgets: [
            { metric: :invocations, stat: 'Sum', period: 60 },
            { metric: :errors, stat: 'Sum', period: 60 }
          ]
        )
      end

      it 'uses custom logical id and settings' do
        compiled = described_class.compile(dashboard, functions: [fn1])

        expect(compiled).to have_key('OpsDashboard')
        resource = compiled['OpsDashboard']
        expect(resource['Properties']['DashboardName']).to eq({ 'Fn::Sub' => '${AWS::StackName}-OpsDashboard' })

        body = JSON.parse(resource['Properties']['DashboardBody']['Fn::Sub'])
        expect(body['widgets'].size).to eq(2)
        expect(body['widgets'][0]['properties']['period']).to eq(60)
        expect(body['widgets'][0]['properties']['metrics']).to eq([
                                                                    ['AWS/Lambda', 'Invocations', 'FunctionName',
                                                                     '${ConvertFunction}']
                                                                  ])
      end
    end
  end
end
