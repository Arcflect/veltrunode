# frozen_string_literal: true

require_relative '../logical_id'
require_relative 'function_compiler'
require_relative 'log_group_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # CloudWatch Logs サブスクリプションフィルター (AWS::Logs::SubscriptionFilter) の CloudFormation コンパイラ
      class SubscriptionFilterCompiler
        attr_reader :function, :filter, :context

        class << self
          def compile(function, filter, context: {})
            new(function, filter, context: context).to_h
          end

          def logical_id_for(function_name, filter_name = nil)
            LogicalId.for_subscription_filter(function_name, filter_name)
          end

          def permission_logical_id_for(function_name, filter_name = nil)
            LogicalId.for_logs_permission(function_name, filter_name)
          end

          def role_logical_id_for(function_name, filter_name = nil)
            LogicalId.for_logs_role(function_name, filter_name)
          end
        end

        def initialize(function, filter, context: {})
          @function = function
          @filter = filter
          @context = freeze_hash(context)
        end

        def to_h
          resources = {}

          # 1. 必要なクロスサービス実行権限の生成
          if filter.lambda_destination?
            perm_id = permission_logical_id
            resources[perm_id] = permission_resource_definition
          elsif (filter.kinesis_destination? || filter.firehose_destination?) && auto_generate_role?
            role_id = role_logical_id
            resources[role_id] = role_resource_definition
          end

          # 2. SubscriptionFilter 本体の生成
          resources[logical_id] = subscription_filter_resource_definition

          deep_sort_keys(resources)
        end

        def logical_id
          self.class.logical_id_for(function_name, filter.name)
        end

        def permission_logical_id
          self.class.permission_logical_id_for(function_name, filter.name)
        end

        def role_logical_id
          self.class.role_logical_id_for(function_name, filter.name)
        end

        def log_group_logical_id
          LogGroupCompiler.logical_id_for(function_name)
        end

        def subscription_filter_resource_definition
          depends_on = [log_group_logical_id]
          depends_on << permission_logical_id if filter.lambda_destination?
          depends_on << role_logical_id if auto_generate_role? && !filter.lambda_destination?

          props = {
            'LogGroupName' => { 'Ref' => log_group_logical_id },
            'DestinationArn' => formatted_destination,
            'FilterPattern' => filter.filter_pattern
          }

          resolved_role = resolve_role_arn
          props['RoleArn'] = resolved_role if resolved_role
          props['Distribution'] = filter.distribution if filter.distribution

          {
            'Type' => 'AWS::Logs::SubscriptionFilter',
            'DependsOn' => depends_on.sort,
            'Properties' => deep_sort_keys(props)
          }
        end

        def permission_resource_definition
          {
            'Type' => 'AWS::Lambda::Permission',
            'Properties' => deep_sort_keys(
              'Action' => 'lambda:InvokeFunction',
              'FunctionName' => formatted_destination,
              'Principal' => { 'Fn::Sub' => 'logs.${AWS::Region}.amazonaws.com' },
              'SourceArn' => { 'Fn::GetAtt' => [log_group_logical_id, 'Arn'] }
            )
          }
        end

        def role_resource_definition
          actions = if filter.kinesis_destination?
                      %w[kinesis:PutRecord kinesis:PutRecords]
                    else
                      %w[firehose:PutRecord firehose:PutRecordBatch]
                    end

          policy_name = if filter.kinesis_destination?
                          'CloudWatchLogsKinesisDelivery'
                        else
                          'CloudWatchLogsFirehoseDelivery'
                        end

          {
            'Type' => 'AWS::IAM::Role',
            'Properties' => deep_sort_keys(
              'AssumeRolePolicyDocument' => {
                'Version' => '2012-10-17',
                'Statement' => [
                  {
                    'Effect' => 'Allow',
                    'Principal' => {
                      'Service' => { 'Fn::Sub' => 'logs.${AWS::Region}.amazonaws.com' }
                    },
                    'Action' => 'sts:AssumeRole'
                  }
                ]
              },
              'Policies' => [
                {
                  'PolicyName' => policy_name,
                  'PolicyDocument' => {
                    'Version' => '2012-10-17',
                    'Statement' => [
                      {
                        'Effect' => 'Allow',
                        'Action' => actions,
                        'Resource' => formatted_destination
                      }
                    ]
                  }
                }
              ]
            )
          }
        end

        private

        def function_name
          function.respond_to?(:logical_name) ? function.logical_name : function.to_s
        end

        def auto_generate_role?
          filter.role_arn.nil? && (filter.kinesis_destination? || filter.firehose_destination?)
        end

        def resolve_role_arn
          return { 'Fn::GetAtt' => [role_logical_id, 'Arn'] } if auto_generate_role?

          format_reference(filter.role_arn) if filter.role_arn
        end

        def formatted_destination
          format_destination(filter.destination)
        end

        def format_destination(dest)
          return dest if dest.is_a?(Hash)

          if dest.respond_to?(:name)
            # DSL::Reference
            return format_symbolic_destination(dest.name)
          end

          return format_symbolic_destination(dest) if dest.is_a?(Symbol)

          str = dest.to_s.strip
          if str.start_with?('arn:aws:')
            str
          else
            { 'Ref' => str }
          end
        end

        def format_symbolic_destination(sym)
          name_str = sym.to_s

          # context[:functions] または対象が Lambda の場合
          fn_id = FunctionCompiler.logical_id_for(name_str)
          { 'Fn::GetAtt' => [fn_id, 'Arn'] }
        end

        def format_reference(ref)
          return ref if ref.is_a?(Hash)
          return { 'Ref' => LogicalId.pascalize(ref.name) } if ref.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(ref) } if ref.is_a?(Symbol)

          str = ref.to_s.strip
          if str.start_with?('arn:aws:')
            str
          else
            { 'Ref' => str }
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
