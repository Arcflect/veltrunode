# frozen_string_literal: true

require 'yaml'
require_relative 'function_compiler'
require_relative '../../model/capability_expander'

module Veltrunode
  module Compiler
    module CloudFormation
      class RoleCompiler
        attr_reader :target, :type, :context

        class << self
          def compile(target, type: :lambda, **)
            new(target, type: type, **).to_h
          end

          def compile_lambda_role(function, **)
            new(function, type: :lambda, **).to_h
          end

          def compile_scheduler_role(schedule, **)
            new(schedule, type: :scheduler, **).to_h
          end

          def to_yaml(target, type: :lambda, **)
            new(target, type: type, **).to_yaml
          end

          def to_yaml_lambda_role(function, **)
            new(function, type: :lambda, **).to_yaml
          end

          def to_yaml_scheduler_role(schedule, **)
            new(schedule, type: :scheduler, **).to_yaml
          end

          def logical_id_for_function(logical_name)
            fn_id = FunctionCompiler.logical_id_for(logical_name)
            "#{fn_id}Role"
          end

          def logical_id_for_schedule(schedule_name)
            base = pascalize(schedule_name)
            base = 'Schedule' if base.empty?
            base = "#{base}Schedule" unless base.end_with?('Schedule')
            "#{base}Role"
          end

          def pascalize(str)
            return '' if str.nil?

            str.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
              part[0].upcase + part[1..]
            end.join
          end
        end

        def initialize(target, type: :lambda, context: {})
          @target = target
          @type = type.to_sym
          @context = freeze_hash(context)
        end

        def logical_id
          if type == :scheduler
            sch_name = extract_val(target, :name) || target.to_s
            self.class.logical_id_for_schedule(sch_name)
          else
            fn_name = extract_val(target, :logical_name) || target.to_s
            self.class.logical_id_for_function(fn_name)
          end
        end

        def resource_type
          'AWS::IAM::Role'
        end

        def properties
          if type == :scheduler
            build_scheduler_role_properties
          else
            build_lambda_role_properties
          end
        end

        def resource_definition
          deep_sort_keys({
                           'Type' => resource_type,
                           'Properties' => properties
                         })
        end

        def to_h
          deep_sort_keys({
                           logical_id => resource_definition
                         })
        end

        def to_yaml
          YAML.dump(to_h)
        end

        private

        def build_lambda_role_properties
          fn_name = extract_val(target, :logical_name) || target.to_s
          fn_logical_id = FunctionCompiler.logical_id_for(fn_name)

          assume_role_policy = {
            'Version' => '2012-10-17',
            'Statement' => [
              {
                'Effect' => 'Allow',
                'Principal' => {
                  'Service' => 'lambda.amazonaws.com'
                },
                'Action' => 'sts:AssumeRole'
              }
            ]
          }

          statements = []

          # 基本ポリシー: CloudWatch Logs への書き込み権限
          log_group_arn = context[:log_group_arn] || context['log_group_arn'] ||
                          { 'Fn::GetAtt' => ["#{fn_logical_id}LogGroup", 'Arn'] }

          statements << {
            'Effect' => 'Allow',
            'Action' => ['logs:CreateLogStream', 'logs:PutLogEvents'],
            'Resource' => [log_group_arn]
          }

          # ケーパビリティから展開されたIAMポリシー
          caps = extract_val(target, :iam_capabilities) || []
          if caps && !caps.empty?
            expanded = Model::CapabilityExpander.expand_all(caps, context)
            statements.concat(expanded)
          end

          # EFSマウント時: elasticfilesystem:ClientMount, ClientWrite 権限を追加
          mounts = extract_val(target, :mounts) || []
          if mounts && !mounts.empty?
            mount_arns = format_mount_arns(mounts)
            unless mount_arns.empty?
              statements << {
                'Effect' => 'Allow',
                'Action' => ['elasticfilesystem:ClientMount', 'elasticfilesystem:ClientWrite'],
                'Resource' => mount_arns
              }
            end
          end

          policy = {
            'PolicyName' => "#{logical_id}Policy",
            'PolicyDocument' => {
              'Version' => '2012-10-17',
              'Statement' => statements
            }
          }

          {
            'AssumeRolePolicyDocument' => assume_role_policy,
            'Policies' => [policy]
          }
        end

        def build_scheduler_role_properties
          target_fn = extract_val(target, :target_function)
          target_arn = resolve_target_function_arn(target_fn)

          assume_role_policy = {
            'Version' => '2012-10-17',
            'Statement' => [
              {
                'Effect' => 'Allow',
                'Principal' => {
                  'Service' => 'scheduler.amazonaws.com'
                },
                'Action' => 'sts:AssumeRole'
              }
            ]
          }

          statement = {
            'Effect' => 'Allow',
            'Action' => ['lambda:InvokeFunction'],
            'Resource' => [target_arn]
          }

          policy = {
            'PolicyName' => "#{logical_id}Policy",
            'PolicyDocument' => {
              'Version' => '2012-10-17',
              'Statement' => [statement]
            }
          }

          {
            'AssumeRolePolicyDocument' => assume_role_policy,
            'Policies' => [policy]
          }
        end

        def resolve_target_function_arn(target_fn)
          return context[:target_function_arn] if context[:target_function_arn]
          return context['target_function_arn'] if context['target_function_arn']

          target_str = target_fn.to_s
          if target_str.start_with?('arn:')
            target_str
          elsif present?(target_str)
            fn_logical_id = FunctionCompiler.logical_id_for(target_str)
            { 'Fn::GetAtt' => [fn_logical_id, 'Arn'] }
          else
            '*'
          end
        end

        def format_mount_arns(mounts)
          Array(mounts).map do |mount_entry|
            raw_arn = extract_mount_arn(mount_entry)
            format_arn_or_ref(raw_arn)
          end.compact
        end

        def extract_mount_arn(mount_entry)
          if mount_entry.respond_to?(:access_point_source)
            mount_entry.access_point_source
          elsif mount_entry.is_a?(Hash)
            mount_entry[:arn] || mount_entry['arn'] || mount_entry['Arn'] ||
              mount_entry[:access_point_source] || mount_entry['access_point_source'] ||
              mount_entry[:name] || mount_entry['name']
          else
            entry_str = mount_entry.to_s
            entry_str.include?(':') ? entry_str.split(':', 2).first : entry_str
          end
        end

        def format_arn_or_ref(val)
          return nil if val.nil?

          val_str = val.to_s
          if val_str.start_with?('arn:')
            val_str
          elsif val.respond_to?(:name)
            { 'Fn::GetAtt' => ["#{self.class.pascalize(val.name)}AccessPoint", 'Arn'] }
          elsif val.is_a?(Hash)
            val
          else
            { 'Fn::GetAtt' => ["#{self.class.pascalize(val_str)}AccessPoint", 'Arn'] }
          end
        end

        def extract_val(obj, method_name)
          return nil if obj.nil?

          if obj.respond_to?(method_name)
            obj.public_send(method_name)
          elsif obj.is_a?(Hash)
            obj[method_name.to_sym] || obj[method_name.to_s]
          end
        end

        def present?(val)
          return false if val.nil?
          return !val.empty? if val.respond_to?(:empty?)

          !val.to_s.strip.empty?
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
