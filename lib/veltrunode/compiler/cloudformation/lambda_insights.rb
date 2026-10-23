# frozen_string_literal: true

module Veltrunode
  module Compiler
    module CloudFormation
      module LambdaInsights
        DEFAULT_X86_VERSION = 53
        DEFAULT_ARM_VERSION = 31

        COMMERCIAL_ACCOUNT = '580247275435'
        CHINA_ACCOUNT = '018784642996'
        GOVCLOUD_ACCOUNT = '519776269227'

        class << self
          def resolve_layer_arn(function, context: {})
            if function.respond_to?(:insights_layer_arn) && function.insights_layer_arn
              return function.insights_layer_arn
            end

            ctx_arn = context[:insights_layer_arn] || context['insights_layer_arn']
            return ctx_arn if ctx_arn

            region_str = resolve_region(context)
            arch = arm64?(function) ? :arm64 : :x86_64
            version = (function.respond_to?(:insights_version) && function.insights_version) || default_version(arch)

            account = account_for(region_str)
            partition = partition_for(region_str)
            layer_name = layer_name_for(arch)

            { 'Fn::Sub' => "arn:#{partition}:lambda:${AWS::Region}:#{account}:layer:#{layer_name}:#{version}" }
          end

          def layer_name_for(architecture)
            architecture.to_s.downcase == 'arm64' ? 'LambdaInsightsExtension-Arm64' : 'LambdaInsightsExtension'
          end

          def default_version(architecture)
            architecture.to_s.downcase == 'arm64' ? DEFAULT_ARM_VERSION : DEFAULT_X86_VERSION
          end

          def account_for(region)
            region_s = region.to_s
            if region_s.start_with?('cn-')
              CHINA_ACCOUNT
            elsif region_s.start_with?('us-gov-')
              GOVCLOUD_ACCOUNT
            else
              COMMERCIAL_ACCOUNT
            end
          end

          def partition_for(region)
            region_s = region.to_s
            if region_s.start_with?('cn-')
              'aws-cn'
            elsif region_s.start_with?('us-gov-')
              'aws-us-gov'
            else
              'aws'
            end
          end

          def layer_arn_for(region: 'ap-northeast-1', architecture: :x86_64, version: nil)
            arch = architecture.to_s.downcase == 'arm64' ? :arm64 : :x86_64
            ver = version || default_version(arch)
            acct = account_for(region)
            part = partition_for(region)
            layer = layer_name_for(arch)
            "arn:#{part}:lambda:#{region}:#{acct}:layer:#{layer}:#{ver}"
          end

          private

          def resolve_region(context)
            app_region = context[:app].aws_region if context[:app].respond_to?(:aws_region)
            (context[:region] || context['region'] || app_region).to_s
          end

          def arm64?(function)
            function.respond_to?(:architecture) && function.architecture.to_s.downcase == 'arm64'
          end
        end
      end
    end
  end
end
