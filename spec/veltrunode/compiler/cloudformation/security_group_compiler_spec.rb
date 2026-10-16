# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/compiler/cloudformation/security_group_compiler'
require 'veltrunode/model/security_group_helper'
require 'veltrunode/dsl/reference'

RSpec.describe Veltrunode::Compiler::CloudFormation::SecurityGroupCompiler do
  let(:valid_vpc_id) { 'vpc-0123456789abcdef0' }

  describe '.compile' do
    context 'with string literal VPC ID' do
      let(:helper) do
        Veltrunode::Model::SecurityGroupHelper.new(
          symbolic_name: :storage,
          vpc_id: valid_vpc_id,
          description: 'EFS NFS communication security group pair',
          tags: { 'Environment' => 'prod' }
        )
      end

      subject(:resources) { described_class.compile(helper) }

      it 'generates four distinct resources for Lambda and EFS NFS communication' do
        expect(resources.keys).to contain_exactly(
          'StorageLambdaSecurityGroup',
          'StorageEfsSecurityGroup',
          'StorageEfsSecurityGroupIngress',
          'StorageLambdaSecurityGroupEgress'
        )
      end

      it 'compiles Lambda Security Group correctly' do
        lambda_sg = resources['StorageLambdaSecurityGroup']
        expect(lambda_sg['Type']).to eq('AWS::EC2::SecurityGroup')
        expect(lambda_sg['Properties']['GroupDescription']).to eq('EFS NFS communication security group pair')
        expect(lambda_sg['Properties']['VpcId']).to eq(valid_vpc_id)
        expected_lambda_tags = [
          { 'Key' => 'Environment', 'Value' => 'prod' },
          { 'Key' => 'Name', 'Value' => 'storage-lambda-sg' }
        ]
        expect(lambda_sg['Properties']['Tags']).to eq(expected_lambda_tags)
      end

      it 'compiles EFS Security Group correctly' do
        efs_sg = resources['StorageEfsSecurityGroup']
        expect(efs_sg['Type']).to eq('AWS::EC2::SecurityGroup')
        expect(efs_sg['Properties']['GroupDescription']).to eq('EFS NFS communication security group pair')
        expect(efs_sg['Properties']['VpcId']).to eq(valid_vpc_id)

        expected_efs_tags = [
          { 'Key' => 'Environment', 'Value' => 'prod' },
          { 'Key' => 'Name', 'Value' => 'storage-efs-sg' }
        ]
        expect(efs_sg['Properties']['Tags']).to eq(expected_efs_tags)
      end

      it 'compiles EFS Ingress rule allowing TCP 2049 from Lambda Security Group' do
        ingress = resources['StorageEfsSecurityGroupIngress']
        expect(ingress['Type']).to eq('AWS::EC2::SecurityGroupIngress')
        expect(ingress['Properties']['GroupId']).to eq({ 'Ref' => 'StorageEfsSecurityGroup' })
        expect(ingress['Properties']['SourceSecurityGroupId']).to eq({ 'Ref' => 'StorageLambdaSecurityGroup' })
        expect(ingress['Properties']['IpProtocol']).to eq('tcp')
        expect(ingress['Properties']['FromPort']).to eq(2049)
        expect(ingress['Properties']['ToPort']).to eq(2049)
      end

      it 'compiles Lambda Egress rule allowing TCP 2049 to EFS Security Group' do
        egress = resources['StorageLambdaSecurityGroupEgress']
        expect(egress['Type']).to eq('AWS::EC2::SecurityGroupEgress')
        expect(egress['Properties']['GroupId']).to eq({ 'Ref' => 'StorageLambdaSecurityGroup' })
        expect(egress['Properties']['DestinationSecurityGroupId']).to eq({ 'Ref' => 'StorageEfsSecurityGroup' })
        expect(egress['Properties']['IpProtocol']).to eq('tcp')
        expect(egress['Properties']['FromPort']).to eq(2049)
        expect(egress['Properties']['ToPort']).to eq(2049)
      end
    end

    context 'with Reference VPC ID' do
      let(:ref) { Veltrunode::DSL::Reference.new(:vpc_id) }
      let(:helper) do
        Veltrunode::Model::SecurityGroupHelper.new(
          symbolic_name: :default,
          vpc_id: ref
        )
      end

      subject(:resources) { described_class.compile(helper) }

      it 'resolves VPC ID to CloudFormation Ref intrinsic function' do
        lambda_sg = resources['LambdaSecurityGroup']
        expect(lambda_sg['Properties']['VpcId']).to eq({ 'Ref' => 'VpcId' })

        efs_sg = resources['EfsSecurityGroup']
        expect(efs_sg['Properties']['VpcId']).to eq({ 'Ref' => 'VpcId' })
      end

      it 'uses default logical IDs when symbolic name is :default' do
        expect(resources.keys).to contain_exactly(
          'LambdaSecurityGroup',
          'EfsSecurityGroup',
          'EfsSecurityGroupIngress',
          'LambdaSecurityGroupEgress'
        )
      end
    end

    context 'with intrinsic Hash VPC ID' do
      let(:fn_import) { { 'Fn::ImportValue' => 'NetworkStack-VpcId' } }
      let(:helper) do
        Veltrunode::Model::SecurityGroupHelper.new(
          symbolic_name: :efs,
          vpc_id: fn_import
        )
      end

      subject(:resources) { described_class.compile(helper) }

      it 'preserves the intrinsic function Hash as VpcId' do
        lambda_sg = resources['EfsLambdaSecurityGroup']
        expect(lambda_sg['Properties']['VpcId']).to eq(fn_import)

        efs_sg = resources['EfsSecurityGroup']
        expect(efs_sg['Properties']['VpcId']).to eq(fn_import)
      end
    end
  end
end
