# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'veltrunode/compiler/cloudformation/s3_notification_compiler'
require 'veltrunode/model/function'
require 'veltrunode/model/event_source'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Compiler::CloudFormation::S3NotificationCompiler do
  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'convert',
      handler: 'convert.handler',
      runtime: 'ruby3.3'
    )
  end

  describe '.compile' do
    it 'compiles managed AWS::S3::Bucket and AWS::Lambda::Permission without circular dependency' do
      source = Veltrunode::Model::EventSource.new(
        s3: {
          bucket: :uploads,
          events: ['s3:ObjectCreated:*'],
          filter: { prefix: 'incoming/', suffix: '.jpg' }
        }
      )

      res = described_class.compile(function, source)

      expect(res).to eq(
        'ConvertFunctionUploadsS3Permission' => {
          'Properties' => {
            'Action' => 'lambda:InvokeFunction',
            'FunctionName' => { 'Fn::GetAtt' => %w[ConvertFunction Arn] },
            'Principal' => 's3.amazonaws.com',
            'SourceAccount' => { 'Ref' => 'AWS::AccountId' },
            'SourceArn' => { 'Fn::Sub' => 'arn:aws:s3:::${AWS::StackName}-uploads' }
          },
          'Type' => 'AWS::Lambda::Permission'
        },
        'UploadsBucket' => {
          'DependsOn' => ['ConvertFunctionUploadsS3Permission'],
          'Properties' => {
            'BucketName' => { 'Fn::Sub' => '${AWS::StackName}-uploads' },
            'NotificationConfiguration' => {
              'LambdaConfigurations' => [
                {
                  'Event' => 's3:ObjectCreated:*',
                  'Filter' => {
                    'S3Key' => {
                      'Rules' => [
                        { 'Name' => 'prefix', 'Value' => 'incoming/' },
                        { 'Name' => 'suffix', 'Value' => '.jpg' }
                      ]
                    }
                  },
                  'Function' => { 'Fn::GetAtt' => %w[ConvertFunction Arn] }
                }
              ]
            }
          },
          'Type' => 'AWS::S3::Bucket'
        }
      )

      # Verify Permission does not reference UploadsBucket via Ref or Fn::GetAtt (preventing circular dependency)
      perm_str = res['ConvertFunctionUploadsS3Permission'].to_s
      expect(perm_str).not_to include('UploadsBucket')
    end

    it 'compiles multiple S3 events without Filter when filter is omitted' do
      source = Veltrunode::Model::EventSource.new(
        s3: {
          bucket: :media_assets,
          events: ['s3:ObjectCreated:Put', 's3:ObjectRemoved:Delete']
        }
      )

      res = described_class.compile(function, source)
      bucket = res['MediaAssetsBucket']
      cfgs = bucket.dig('Properties', 'NotificationConfiguration', 'LambdaConfigurations')

      expect(bucket.dig('Properties', 'BucketName')).to eq('Fn::Sub' => '${AWS::StackName}-media-assets')
      expect(cfgs).to eq([
                           {
                             'Event' => 's3:ObjectCreated:Put',
                             'Function' => { 'Fn::GetAtt' => %w[ConvertFunction Arn] }
                           },
                           {
                             'Event' => 's3:ObjectRemoved:Delete',
                             'Function' => { 'Fn::GetAtt' => %w[ConvertFunction Arn] }
                           }
                         ])
    end

    it 'compiles only AWS::Lambda::Permission when bucket is an external ARN' do
      source = Veltrunode::Model::EventSource.new(
        s3: {
          bucket: 'arn:aws:s3:::existing-company-uploads',
          events: ['s3:ObjectCreated:*'],
          filter: { prefix: 'raw/' }
        }
      )

      res = described_class.compile(function, source)

      expect(res.keys).to eq(['ConvertFunctionExistingCompanyUploadsS3Permission'])
      expect(res['ConvertFunctionExistingCompanyUploadsS3Permission']).to eq(
        'Properties' => {
          'Action' => 'lambda:InvokeFunction',
          'FunctionName' => { 'Fn::GetAtt' => %w[ConvertFunction Arn] },
          'Principal' => 's3.amazonaws.com',
          'SourceAccount' => { 'Ref' => 'AWS::AccountId' },
          'SourceArn' => 'arn:aws:s3:::existing-company-uploads'
        },
        'Type' => 'AWS::Lambda::Permission'
      )
    end

    it 'compiles only AWS::Lambda::Permission with Fn::Sub when bucket is a parameter ref(:input_bucket)' do
      source = Veltrunode::Model::EventSource.new(
        s3: {
          bucket: Veltrunode::DSL::Reference.new(:input_bucket),
          events: ['s3:ObjectCreated:*']
        }
      )

      res = described_class.compile(function, source)

      expect(res.keys).to eq(['ConvertFunctionInputBucketS3Permission'])
      expect(res['ConvertFunctionInputBucketS3Permission']['Properties']['SourceArn']).to eq(
        'Fn::Sub' => 'arn:aws:s3:::${InputBucket}'
      )
    end
  end

  describe '.merge_into_resources!' do
    it 'merges LambdaConfigurations and DependsOn when multiple triggers share the same managed bucket' do
      resize_fn = Veltrunode::Model::Function.new(
        logical_name: 'resize',
        handler: 'resize.handler',
        runtime: 'ruby3.3'
      )

      jpg_source = Veltrunode::Model::EventSource.new(
        s3: { bucket: :uploads, events: ['s3:ObjectCreated:*'], filter: { suffix: '.jpg' } }
      )
      png_source = Veltrunode::Model::EventSource.new(
        s3: { bucket: :uploads, events: ['s3:ObjectCreated:*'], filter: { suffix: '.png' } }
      )

      resources = {}
      described_class.merge_into_resources!(resources, described_class.compile(function, jpg_source))
      described_class.merge_into_resources!(resources, described_class.compile(resize_fn, png_source))

      expect(resources).to have_key('ConvertFunctionUploadsS3Permission')
      expect(resources).to have_key('ResizeFunctionUploadsS3Permission')
      expect(resources).to have_key('UploadsBucket')

      bucket = resources['UploadsBucket']
      expect(bucket['DependsOn']).to eq(%w[ConvertFunctionUploadsS3Permission ResizeFunctionUploadsS3Permission])
      cfgs = bucket.dig('Properties', 'NotificationConfiguration', 'LambdaConfigurations')
      expect(cfgs.size).to eq(2)
    end
  end

  describe '.to_yaml' do
    it 'produces valid YAML string containing Bucket and Permission' do
      source = Veltrunode::Model::EventSource.new(
        s3: { bucket: :uploads, filter: { prefix: 'incoming/' } }
      )

      yaml_str = described_class.to_yaml(function, source)
      parsed = YAML.safe_load(yaml_str)

      expect(parsed).to have_key('UploadsBucket')
      expect(parsed).to have_key('ConvertFunctionUploadsS3Permission')
    end
  end
end
