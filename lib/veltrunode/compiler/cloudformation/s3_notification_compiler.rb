# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'function_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # S3 バケット通知設定 (AWS::S3::Bucket) および呼び出し権限 (AWS::Lambda::Permission) の CloudFormation コンパイラ
      #
      # CloudFormation における AWS::S3::Bucket -> AWS::Lambda::Permission -> AWS::S3::Bucket の循環依存を回避するため、
      # マネージドバケットの BucketName と Permission の SourceArn の双方を Fn::Sub による決定論的な命名規則
      # (${AWS::StackName}-<bucket>) で解決し、Bucket 側から Permission への単方向 DependsOn のみを構成します。
      class S3NotificationCompiler
        attr_reader :function, :event_source, :context

        class << self
          def compile(function, event_source, **)
            new(function, event_source, **).to_h
          end

          def to_yaml(function, event_source, **)
            new(function, event_source, **).to_yaml
          end

          def bucket_logical_id_for(bucket_identifier)
            LogicalId.for_bucket(bucket_identifier)
          end
          alias logical_id_for bucket_logical_id_for

          def permission_logical_id_for(function_name, bucket_identifier = nil)
            LogicalId.for_s3_permission(function_name, bucket_identifier)
          end

          def merge_into_resources!(resources, compiled_hash)
            compiled_hash.each do |logical_id, definition|
              if resources.key?(logical_id) &&
                 resources[logical_id]['Type'] == 'AWS::S3::Bucket' &&
                 definition['Type'] == 'AWS::S3::Bucket'
                merge_bucket_resource!(resources[logical_id], definition)
              else
                resources[logical_id] = definition
              end
            end
            resources
          end

          private

          def merge_bucket_resource!(existing, incoming)
            existing_deps = Array(existing['DependsOn'])
            incoming_deps = Array(incoming['DependsOn'])
            merged_deps = (existing_deps + incoming_deps).uniq
            existing['DependsOn'] = merged_deps unless merged_deps.empty?

            existing_props = (existing['Properties'] ||= {})
            existing_notif = (existing_props['NotificationConfiguration'] ||= {})
            existing_cfgs = (existing_notif['LambdaConfigurations'] ||= [])
            incoming_cfgs = incoming.dig('Properties', 'NotificationConfiguration', 'LambdaConfigurations') || []
            existing_cfgs.concat(incoming_cfgs)
          end
        end

        def initialize(function, event_source, context: {})
          @function = function
          @event_source = event_source
          @context = freeze_hash(context)
        end

        def bucket_logical_id
          self.class.bucket_logical_id_for(event_source.bucket_identifier)
        end
        alias logical_id bucket_logical_id

        def permission_logical_id
          fn_name = extract_name(function)
          self.class.permission_logical_id_for(fn_name, event_source.bucket_identifier)
        end

        def normalized_bucket_name
          event_source.bucket_identifier.to_s.downcase.tr('_', '-').gsub(/[^a-z0-9.-]/, '-')
        end

        def managed_bucket_name_expr
          { 'Fn::Sub' => "${AWS::StackName}-#{normalized_bucket_name}" }
        end

        def managed_bucket_arn_expr
          { 'Fn::Sub' => "arn:aws:s3:::${AWS::StackName}-#{normalized_bucket_name}" }
        end

        def lambda_configurations
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)
          rules = event_source.filter_rules

          event_source.events.map do |evt|
            cfg = {
              'Event' => evt,
              'Function' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] }
            }
            cfg['Filter'] = { 'S3Key' => { 'Rules' => rules } } unless rules.empty?
            deep_sort_keys(cfg)
          end
        end

        def bucket_resource_definition
          deep_sort_keys(
            'DependsOn' => [permission_logical_id],
            'Properties' => {
              'BucketName' => managed_bucket_name_expr,
              'NotificationConfiguration' => {
                'LambdaConfigurations' => lambda_configurations
              }
            },
            'Type' => 'AWS::S3::Bucket'
          )
        end
        alias resource_definition bucket_resource_definition

        def permission_resource_definition
          fn_name = extract_name(function)
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          deep_sort_keys(
            'Properties' => {
              'Action' => 'lambda:InvokeFunction',
              'FunctionName' => { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] },
              'Principal' => 's3.amazonaws.com',
              'SourceAccount' => { 'Ref' => 'AWS::AccountId' },
              'SourceArn' => resolve_source_arn
            },
            'Type' => 'AWS::Lambda::Permission'
          )
        end

        def to_h
          res = {
            permission_logical_id => permission_resource_definition
          }
          res[bucket_logical_id] = bucket_resource_definition if event_source.managed_bucket?
          deep_sort_keys(res)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def extract_name(target)
          if target.respond_to?(:logical_name)
            target.logical_name
          elsif !target.is_a?(Symbol) && target.respond_to?(:name)
            target.name
          else
            target.to_s
          end
        end

        def resolve_source_arn
          return managed_bucket_arn_expr if event_source.managed_bucket?

          bucket = event_source.bucket
          if bucket.is_a?(Hash)
            ref_key = bucket[:ref] || bucket['ref'] || bucket[:Ref] || bucket['Ref']
            if ref_key
              param_name = LogicalId.pascalize(ref_key)
              return { 'Fn::Sub' => "arn:aws:s3:::${#{param_name}}" }
            end

            return bucket
          end

          if !bucket.is_a?(Symbol) && bucket.respond_to?(:name)
            param_name = LogicalId.pascalize(bucket.name)
            return { 'Fn::Sub' => "arn:aws:s3:::${#{param_name}}" }
          end

          bucket.to_s.strip
        end

        def freeze_hash(hash)
          hash.transform_values { |v| v.is_a?(Hash) ? freeze_hash(v) : v }.freeze
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), memo|
              memo[k] = deep_sort_keys(v)
            end.sort.to_h
          when Array
            obj.map { |item| deep_sort_keys(item) }
          else
            obj
          end
        end
      end
    end
  end
end
