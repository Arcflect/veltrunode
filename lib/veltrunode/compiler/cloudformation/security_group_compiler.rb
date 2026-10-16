# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'

module Veltrunode
  module Compiler
    module CloudFormation
      # EFSマウント用セキュリティグループおよびルールのコンパイラ
      class SecurityGroupCompiler
        attr_reader :helper, :context

        class << self
          def compile(helper, **)
            new(helper, **).to_h
          end

          def to_yaml(helper, **)
            new(helper, **).to_yaml
          end

          def lambda_security_group_id_for(name)
            LogicalId.for_lambda_security_group(name)
          end

          def efs_security_group_id_for(name)
            LogicalId.for_efs_security_group(name)
          end

          def ingress_id_for(name)
            LogicalId.for_security_group_ingress(name)
          end

          def egress_id_for(name)
            LogicalId.for_security_group_egress(name)
          end
        end

        def initialize(helper, context: {})
          @helper = helper
          @context = freeze_hash(context)
        end

        def symbolic_name
          if helper.respond_to?(:symbolic_name)
            helper.symbolic_name
          elsif helper.is_a?(Hash)
            helper[:symbolic_name] || helper['symbolic_name'] || helper[:name] || helper['name'] || :default
          else
            helper.to_s
          end
        end

        def lambda_security_group_id
          self.class.lambda_security_group_id_for(symbolic_name)
        end

        def efs_security_group_id
          self.class.efs_security_group_id_for(symbolic_name)
        end

        def ingress_id
          self.class.ingress_id_for(symbolic_name)
        end

        def egress_id
          self.class.egress_id_for(symbolic_name)
        end

        def to_h
          resources = {}

          # 1. Lambda Security Group
          resources[lambda_security_group_id] = lambda_security_group_definition

          # 2. EFS Security Group
          resources[efs_security_group_id] = efs_security_group_definition

          # 3. EFS Ingress Rule (TCP 2049 from Lambda SG)
          resources[ingress_id] = ingress_rule_definition

          # 4. Lambda Egress Rule (TCP 2049 to EFS SG)
          resources[egress_id] = egress_rule_definition

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def lambda_security_group_definition
          default_desc = "Security group for Lambda function to communicate with EFS (#{symbolic_name})"
          desc = extract_prop(:description) || default_desc
          props = {
            'GroupDescription' => desc,
            'VpcId' => format_vpc_id(extract_prop(:vpc_id))
          }

          tags = format_tags(extract_prop(:tags), default_name: "#{symbolic_name}-lambda-sg")
          props['Tags'] = tags unless tags.empty?

          {
            'Type' => 'AWS::EC2::SecurityGroup',
            'Properties' => deep_sort_keys(props)
          }
        end

        def efs_security_group_definition
          desc = extract_prop(:description) || "Security group for EFS mount target (#{symbolic_name})"
          props = {
            'GroupDescription' => desc,
            'VpcId' => format_vpc_id(extract_prop(:vpc_id))
          }

          tags = format_tags(extract_prop(:tags), default_name: "#{symbolic_name}-efs-sg")
          props['Tags'] = tags unless tags.empty?

          {
            'Type' => 'AWS::EC2::SecurityGroup',
            'Properties' => deep_sort_keys(props)
          }
        end

        def ingress_rule_definition
          props = {
            'GroupId' => { 'Ref' => efs_security_group_id },
            'SourceSecurityGroupId' => { 'Ref' => lambda_security_group_id },
            'IpProtocol' => 'tcp',
            'FromPort' => 2049,
            'ToPort' => 2049,
            'Description' => 'Allow NFS inbound traffic from Lambda security group'
          }

          {
            'Type' => 'AWS::EC2::SecurityGroupIngress',
            'Properties' => deep_sort_keys(props)
          }
        end

        def egress_rule_definition
          props = {
            'GroupId' => { 'Ref' => lambda_security_group_id },
            'DestinationSecurityGroupId' => { 'Ref' => efs_security_group_id },
            'IpProtocol' => 'tcp',
            'FromPort' => 2049,
            'ToPort' => 2049,
            'Description' => 'Allow NFS outbound traffic to EFS security group'
          }

          {
            'Type' => 'AWS::EC2::SecurityGroupEgress',
            'Properties' => deep_sort_keys(props)
          }
        end

        def format_vpc_id(raw_vpc_id)
          return raw_vpc_id if raw_vpc_id.is_a?(Hash)

          if raw_vpc_id.respond_to?(:name)
            # DSL::Reference
            return { 'Ref' => LogicalId.pascalize(raw_vpc_id.name) }
          end

          return { 'Ref' => LogicalId.pascalize(raw_vpc_id) } if raw_vpc_id.is_a?(Symbol)

          str = raw_vpc_id.to_s.strip
          if str.start_with?('vpc-')
            str
          else
            { 'Ref' => str }
          end
        end

        def format_tags(tags, default_name:)
          list = []
          tag_hash = tags.is_a?(Hash) ? tags : {}

          has_name = tag_hash.keys.any? { |k| k.to_s.casecmp('name').zero? }
          list << { 'Key' => 'Name', 'Value' => default_name } unless has_name

          tag_hash.each do |k, v|
            list << { 'Key' => k.to_s, 'Value' => v.to_s }
          end

          list.sort_by { |t| t['Key'] }
        end

        def extract_prop(key)
          if helper.respond_to?(key)
            helper.public_send(key)
          elsif helper.is_a?(Hash)
            helper[key.to_sym] || helper[key.to_s]
          end
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.keys.sort_by(&:to_s).to_h do |k|
              [k.to_s, deep_sort_keys(obj[k])]
            end
          when Array
            obj.map { |v| deep_sort_keys(v) }
          else
            obj
          end
        end

        def freeze_hash(hash)
          return {}.freeze if hash.nil?

          hash.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = v
          end.freeze
        end
      end
    end
  end
end
