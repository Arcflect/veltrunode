# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require_relative 'access_point_compiler'
require_relative 'alarm_compiler'
require_relative 'function_compiler'
require_relative 'layer_version_compiler'
require_relative 'log_group_compiler'
require_relative 'queue_compiler'
require_relative 'role_compiler'
require_relative 'schedule_compiler'
require_relative 'security_group_compiler'
require_relative 'subscription_filter_compiler'
require_relative 'dashboard_compiler'
require_relative 'event_invoke_config_compiler'
require_relative 'event_source_mapping_compiler'
require_relative 'sns_subscription_compiler'
require_relative 's3_notification_compiler'
require_relative '../../graph/resource_graph'
require_relative '../../version'

module Veltrunode
  module Compiler
    module CloudFormation
      class TemplateCompiler
        DEFAULT_TEMPLATE_VERSION = '2010-09-09'

        attr_reader :application, :defaults, :context, :parameters, :description

        class << self
          def compile(application, **)
            new(application, **).to_h
          end

          def to_yaml(application, **)
            new(application, **).to_yaml
          end

          def generate(application, output_path: 'build/template.yml', **)
            new(application, **).generate(output_path)
          end
        end

        def initialize(application, defaults: {}, context: {}, parameters: {}, description: nil)
          @application = application
          @defaults = freeze_hash(defaults)
          @parameters = freeze_hash(parameters)
          @description = description
          @context = freeze_hash(resolve_initial_context(context))
        end

        def to_h
          template = {
            'AWSTemplateFormatVersion' => DEFAULT_TEMPLATE_VERSION,
            'Description' => format_description
          }

          params = format_parameters
          template['Parameters'] = params unless params.empty?

          template['Resources'] = format_resources

          outs = format_outputs
          template['Outputs'] = outs unless outs.empty?

          template
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def generate(output_path = 'build/template.yml')
          hash = to_h
          content = YAML.dump(hash)
          FileUtils.mkdir_p(File.dirname(output_path))
          File.write(output_path, content)
          hash
        end

        private

        def format_description
          return description.to_s if description

          app_name = application.respond_to?(:name) ? application.name : 'Application'
          app_stage = application.respond_to?(:stage) ? application.stage : 'dev'
          "#{app_name} - #{app_stage} (compiled by Veltrunode v#{Veltrunode::VERSION})"
        end

        def format_parameters
          params = {
            'ArtifactBucket' => {
              'Description' => 'S3 bucket name where function and layer zip packages are stored',
              'Type' => 'String'
            }
          }

          # Include context parameters (defaults)
          ctx_params = context[:parameters] || context['parameters']
          if ctx_params.is_a?(Hash)
            ctx_params.each do |k, v|
              params[k.to_s] = v.is_a?(Hash) ? v : { 'Type' => 'String', 'Default' => v.to_s }
            end
          end

          # Include explicitly specified parameters (highest precedence)
          parameters.each do |k, v|
            param_def = if v.is_a?(Hash)
                          v
                        else
                          { 'Type' => 'String', 'Default' => v.to_s }
                        end
            params[k.to_s] = param_def
          end

          # Include referenced VPC ID parameters from security group helpers
          sg_nodes = extract_collection(:security_groups)
          sg_nodes.each do |sg|
            v_id = extract_vpc_id_from_sg(sg)
            param_key = resolve_vpc_param_key(v_id)
            next if param_key.nil? || params.key?(param_key)

            params[param_key] = {
              'Description' => 'VPC ID for EFS and Lambda security groups',
              'Type' => 'AWS::EC2::VPC::Id'
            }
          end

          # Include referenced SNS topic ARN parameters from alarms and subscription filters
          fn_nodes = extract_collection(:functions)
          fn_nodes.each do |fn|
            if fn.respond_to?(:alarms) && fn.alarms
              Array(fn.alarms).each do |alarm|
                Array(alarm.alarm_actions).each do |act|
                  param_key = resolve_sns_topic_param_key(act)
                  next if param_key.nil? || params.key?(param_key)

                  params[param_key] = {
                    'Description' => "SNS topic ARN for #{param_key}",
                    'Type' => 'String'
                  }
                end
              end
            end

            if fn.respond_to?(:event_sources) && fn.event_sources
              Array(fn.event_sources).each do |source|
                if source.respond_to?(:sns?) && source.sns?
                  param_key = resolve_sns_topic_param_key(source.topic)
                  if param_key && !params.key?(param_key)
                    params[param_key] = {
                      'Description' => "SNS topic ARN for #{param_key}",
                      'Type' => 'String'
                    }
                  end
                elsif source.respond_to?(:s3?) && source.s3?
                  param_key = resolve_s3_bucket_param_key(source.bucket)
                  if param_key && !params.key?(param_key)
                    params[param_key] = {
                      'Description' => "S3 bucket name for #{param_key}",
                      'Type' => 'String'
                    }
                  end
                end
              end
            end

            next unless fn.respond_to?(:subscription_filters) && fn.subscription_filters

            Array(fn.subscription_filters).each do |filter|
              dest_param = resolve_subscription_destination_param_key(filter.destination)
              if dest_param && !params.key?(dest_param)
                params[dest_param] = {
                  'Description' => "Destination ARN for #{dest_param}",
                  'Type' => 'String'
                }
              end

              role_param = resolve_subscription_role_param_key(filter.role_arn)
              next unless role_param && !params.key?(role_param)

              params[role_param] = {
                'Description' => "Role ARN for #{role_param}",
                'Type' => 'String'
              }
            end

            # Async invoke destination parameters
            next unless fn.respond_to?(:async_invoke?) && fn.async_invoke? && fn.async_invoke&.destination_config?

            [fn.async_invoke.on_success, fn.async_invoke.on_failure].compact.each do |dest|
              dest_param = resolve_async_destination_param_key(dest)
              next if dest_param.nil? || params.key?(dest_param)

              params[dest_param] = {
                'Description' => "Destination ARN for #{dest_param}",
                'Type' => 'String'
              }
            end
          end

          # Include referenced SNS topic ARN parameters from schedule DLQ alarms
          sched_nodes = extract_collection(:schedules)
          sched_nodes.each do |sched|
            next unless sched.respond_to?(:dlq_alarm?) && sched.dlq_alarm?

            topic = sched.respond_to?(:dlq_alarm_topic) ? sched.dlq_alarm_topic : nil
            next if topic.nil?

            param_key = resolve_sns_topic_param_key(topic)
            next if param_key.nil? || params.key?(param_key)

            params[param_key] = {
              'Description' => "SNS topic ARN for #{param_key}",
              'Type' => 'String'
            }
          end

          deep_sort_keys(params)
        end

        def format_resources
          resources = {}

          reused_layers_map = resolve_reused_layers

          # 1. Compile Layers
          layer_nodes = extract_collection(:layers)
          layer_nodes.each do |layer|
            layer_name = extract_name(layer).to_s
            next if reused_layers_map.key?(layer_name)

            layer_res = LayerVersionCompiler.compile(layer, context: context)
            resources.merge!(layer_res)
          end

          # 2. Compile Queues (e.g. newly created DLQs referenced in schedules)
          generated_queues = discover_generated_queues
          generated_queues.each do |q_name|
            queue_res = QueueCompiler.compile(q_name, context: context)
            resources.merge!(queue_res)
          end

          # 2.1. Compile DLQ Alarms
          sched_nodes = extract_collection(:schedules)
          compiled_dlq_alarms = {}
          sched_nodes.each do |sched|
            next unless sched.respond_to?(:dlq_alarm?) && sched.dlq_alarm?

            q_name = sched.respond_to?(:dlq_name) ? sched.dlq_name : nil
            next if q_name.nil? || q_name.empty?
            next if compiled_dlq_alarms.key?(q_name)

            alarm_res = DlqAlarmCompiler.compile(q_name, topic: sched.dlq_alarm_topic, context: context)
            resources.merge!(alarm_res)
            compiled_dlq_alarms[q_name] = true
          end

          # 3. Compile EFS Access Points (AWS::EFS::AccessPoint)
          mount_nodes = extract_collection(:mounts)
          mount_map = mount_nodes.each_with_object({}) do |mount, memo|
            name = extract_name(mount).to_s
            next if name.strip.empty?

            memo[name] = mount
          end

          mount_nodes.each do |mount|
            next unless mount.respond_to?(:managed_access_point?) && mount.managed_access_point?

            ap_res = AccessPointCompiler.compile(mount, context: context)
            resources.merge!(ap_res)
          end

          # 4. Compile Security Groups (AWS::EC2::SecurityGroup, Ingress, Egress)
          sg_nodes = extract_collection(:security_groups)
          sg_nodes.each do |sg|
            sg_res = SecurityGroupCompiler.compile(sg, context: context)
            resources.merge!(sg_res)
          end

          # 5. Compile Functions (Role, LogGroup, Function with DependsOn)
          fn_nodes = extract_collection(:functions)
          layer_ref_map = layer_nodes.each_with_object({}) do |layer, memo|
            name = extract_name(layer).to_s
            next if name.strip.empty?

            memo[name] = if reused_layers_map.key?(name)
                           reused_layers_map[name]
                         else
                           { 'Ref' => LayerVersionCompiler.logical_id_for(name) }
                         end
          end
          local_layer_names = layer_ref_map.keys.reject { |k| reused_layers_map.key?(k) }

          fn_nodes.each do |fn|
            # Lambda Execution Role
            role_res = RoleCompiler.compile_lambda_role(
              fn,
              context: context.merge(mount_map: mount_map),
              mount_map: mount_map
            )
            resources.merge!(role_res)

            # CloudWatch Log Group
            log_res = LogGroupCompiler.compile(
              fn,
              defaults: resolve_function_defaults,
              context: context
            )
            resources.merge!(log_res)

            # Lambda Function with Graph-aware DependsOn
            depends_on = resolve_function_dependencies(fn, local_layer_names, mount_map)
            fn_res = FunctionCompiler.compile(
              fn,
              context: context.merge(security_groups: sg_nodes),
              depends_on: depends_on,
              layer_map: layer_ref_map,
              mount_map: mount_map
            )
            resources.merge!(fn_res)

            # CloudWatch Alarms
            if fn.respond_to?(:alarms) && fn.alarms
              Array(fn.alarms).each do |alarm|
                alarm_res = AlarmCompiler.compile(fn, alarm, context: context)
                resources.merge!(alarm_res)
              end
            end

            # CloudWatch Logs Subscription Filters
            if fn.respond_to?(:subscription_filters) && fn.subscription_filters
              Array(fn.subscription_filters).each do |filter|
                sf_res = SubscriptionFilterCompiler.compile(fn, filter, context: context)
                resources.merge!(sf_res)
              end
            end

            # EventSourceMapping / SNS Subscription / S3 Notification
            if fn.respond_to?(:event_sources) && fn.event_sources
              Array(fn.event_sources).each do |source|
                if source.respond_to?(:sns?) && source.sns?
                  sns_res = SnsSubscriptionCompiler.compile(fn, source, context: context)
                  resources.merge!(sns_res)
                elsif source.respond_to?(:s3?) && source.s3?
                  s3_res = S3NotificationCompiler.compile(fn, source, context: context)
                  S3NotificationCompiler.merge_into_resources!(resources, s3_res)
                else
                  esm_res = EventSourceMappingCompiler.compile(fn, source, context: context)
                  resources.merge!(esm_res)
                end
              end
            end

            # EventInvokeConfig (AWS::Lambda::EventInvokeConfig)
            next unless fn.respond_to?(:async_invoke?) && fn.async_invoke?

            eic_res = EventInvokeConfigCompiler.compile(fn, context: context)
            resources.merge!(eic_res)
          end

          # 6. Compile Schedules (Role, Schedule)
          sched_nodes = extract_collection(:schedules)
          sched_nodes.each do |sched|
            role_res = RoleCompiler.compile_scheduler_role(sched, context: context)
            resources.merge!(role_res)

            sched_res = ScheduleCompiler.compile(sched, context: context)
            resources.merge!(sched_res)
          end

          # 7. Compile Dashboard (AWS::CloudWatch::Dashboard)
          if application.respond_to?(:dashboard) && application.dashboard&.enabled?
            dashboard_res = DashboardCompiler.compile(
              application.dashboard,
              functions: fn_nodes,
              context: context
            )
            resources.merge!(dashboard_res)
          end

          deep_sort_keys(resources)
        end

        def format_outputs
          outputs = {}

          # Application Stack Metadata
          if application.respond_to?(:name)
            outputs['ApplicationName'] = {
              'Description' => 'Veltrunode application name',
              'Value' => application.name.to_s
            }
          end

          if application.respond_to?(:stage)
            outputs['ApplicationStage'] = {
              'Description' => 'Veltrunode application stage',
              'Value' => application.stage.to_s
            }
          end

          # Function Outputs
          fn_nodes = extract_collection(:functions)
          fn_nodes.each do |fn|
            fn_name = extract_name(fn)
            fn_id = FunctionCompiler.logical_id_for(fn_name)

            outputs["#{fn_id}Arn"] = {
              'Description' => "ARN of #{fn_name} Lambda function",
              'Value' => { 'Fn::GetAtt' => [fn_id, 'Arn'] },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{fn_id}Arn" } }
            }

            outputs["#{fn_id}Name"] = {
              'Description' => "Name of #{fn_name} Lambda function",
              'Value' => { 'Ref' => fn_id },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{fn_id}Name" } }
            }
          end

          # Layer Outputs
          reused_layers_map = resolve_reused_layers
          layer_nodes = extract_collection(:layers)
          layer_nodes.each do |layer|
            layer_name = extract_name(layer)
            layer_id = LayerVersionCompiler.logical_id_for(layer_name)

            output_val = if reused_layers_map.key?(layer_name.to_s)
                           reused_layers_map[layer_name.to_s]
                         else
                           { 'Ref' => layer_id }
                         end

            outputs["#{layer_id}Arn"] = {
              'Description' => "ARN of #{layer_name} Lambda layer version",
              'Value' => output_val,
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{layer_id}Arn" } }
            }
          end

          # Schedule Outputs
          sched_nodes = extract_collection(:schedules)
          sched_nodes.each do |sched|
            sched_name = extract_name(sched)
            sched_id = ScheduleCompiler.logical_id_for(sched_name)

            outputs["#{sched_id}Arn"] = {
              'Description' => "ARN of #{sched_name} EventBridge schedule",
              'Value' => { 'Fn::GetAtt' => [sched_id, 'Arn'] },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{sched_id}Arn" } }
            }
          end

          # EFS Access Point Outputs
          mount_nodes = extract_collection(:mounts)
          mount_nodes.each do |mount|
            next unless mount.respond_to?(:managed_access_point?) && mount.managed_access_point?

            mount_name = extract_name(mount)
            ap_id = AccessPointCompiler.logical_id_for(mount_name)

            outputs["#{ap_id}Arn"] = {
              'Description' => "ARN of #{mount_name} managed EFS access point",
              'Value' => { 'Fn::GetAtt' => [ap_id, 'Arn'] },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{ap_id}Arn" } }
            }
          end

          # Security Group Outputs
          sg_nodes = extract_collection(:security_groups)
          sg_nodes.each do |sg|
            sg_name = extract_name(sg)
            lambda_sg_id = SecurityGroupCompiler.lambda_security_group_id_for(sg_name)
            efs_sg_id = SecurityGroupCompiler.efs_security_group_id_for(sg_name)

            outputs["#{lambda_sg_id}Id"] = {
              'Description' => "Security group ID of #{sg_name} Lambda function",
              'Value' => { 'Ref' => lambda_sg_id },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{lambda_sg_id}Id" } }
            }

            outputs["#{efs_sg_id}Id"] = {
              'Description' => "Security group ID of #{sg_name} EFS mount target",
              'Value' => { 'Ref' => efs_sg_id },
              'Export' => { 'Name' => { 'Fn::Sub' => "${AWS::StackName}-#{efs_sg_id}Id" } }
            }
          end

          # Dashboard Output
          if application.respond_to?(:dashboard) && application.dashboard&.enabled?
            dashboard_id = DashboardCompiler.logical_id_for(application.dashboard.name)
            outputs['DashboardUrl'] = {
              'Description' => 'URL of CloudWatch Dashboard',
              'Value' => {
                'Fn::Sub' => "https://${AWS::Region}.console.aws.amazon.com/cloudwatch/home?region=${AWS::Region}#dashboards/dashboard/${#{dashboard_id}}"
              }
            }
          end

          deep_sort_keys(outputs)
        end

        def resolve_function_dependencies(fn, local_layer_names, mount_map = {})
          fn_name = extract_name(fn)
          fn_id = FunctionCompiler.logical_id_for(fn_name)

          deps = ["#{fn_id}LogGroup"]

          # If attached layers are locally defined in this application, add their LayerVersion logical IDs
          attached_layers = fn.respond_to?(:layers) ? Array(fn.layers) : []
          attached_layers.each do |l_ref|
            l_name = extract_name(l_ref)
            deps << LayerVersionCompiler.logical_id_for(l_name) if local_layer_names.include?(l_name)
          end

          # If attached mounts are managed access points, add their AccessPoint logical IDs
          attached_mounts = fn.respond_to?(:mounts) ? Array(fn.mounts) : []
          attached_mounts.each do |m_ref|
            m_name = extract_mount_name(m_ref)
            next if m_name.nil?

            mount_obj = mount_map[m_name.to_s]
            if mount_obj.respond_to?(:managed_access_point?) && mount_obj.managed_access_point?
              deps << AccessPointCompiler.logical_id_for(m_name)
            end
          end

          deps.uniq.sort
        end

        def extract_mount_name(m_ref)
          if m_ref.respond_to?(:symbolic_name)
            m_ref.symbolic_name
          elsif m_ref.respond_to?(:name)
            m_ref.name
          elsif m_ref.is_a?(Hash)
            m_ref[:name] || m_ref['name'] || m_ref[:symbolic_name] || m_ref['symbolic_name']
          else
            m_ref.to_s.split(':', 2).first
          end
        end

        def discover_generated_queues
          sched_nodes = extract_collection(:schedules)
          queues = []

          sched_nodes.each do |sched|
            q_name = if sched.respond_to?(:dlq_name) && sched.dlq_name
                       sched.dlq_name
                     else
                       dlq = sched.respond_to?(:dlq) ? sched.dlq : nil
                       next if dlq.nil? || dlq.is_a?(Hash)

                       dlq_str = dlq.to_s.strip
                       next if dlq_str.empty? || dlq_str.start_with?('arn:')

                       dlq_str
                     end

            next if q_name.nil? || q_name.empty? || q_name.start_with?('arn:')

            queues << q_name
          end

          queues.uniq.sort
        end

        def resolve_function_defaults
          if application.respond_to?(:runtime_defaults) && application.runtime_defaults
            application.runtime_defaults
          else
            defaults
          end
        end

        def extract_collection(name)
          if application.respond_to?(name) && application.public_send(name)
            Array(application.public_send(name))
          elsif application.is_a?(Hash)
            Array(application[name.to_sym] || application[name.to_s])
          else
            []
          end
        end

        def extract_name(item)
          if item.respond_to?(:logical_name)
            item.logical_name
          elsif item.respond_to?(:symbolic_name)
            item.symbolic_name
          elsif item.respond_to?(:name)
            item.name
          elsif item.is_a?(Hash)
            item[:logical_name] || item['logical_name'] ||
              item[:symbolic_name] || item['symbolic_name'] ||
              item[:name] || item['name']
          else
            item.to_s
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

        def resolve_initial_context(user_context)
          app_ctx = build_application_context
          base = {}
          app_ctx.each { |k, v| base[k.to_s] = v }
          (user_context || {}).each { |k, v| base[k.to_s] = v }
          base
        end

        def build_application_context
          app_ctx = {}
          region = extract_app_val(:region)
          app_ctx[:region] = region.to_s if region

          account = extract_app_val(:account_constraint) || extract_app_val(:account)
          app_ctx[:account] = account.to_s if account

          stage = extract_app_val(:stage)
          app_ctx[:stage] = stage.to_s if stage

          app_ctx
        end

        def extract_app_val(method_name)
          if application.respond_to?(method_name) && application.public_send(method_name)
            application.public_send(method_name)
          elsif application.is_a?(Hash)
            application[method_name.to_sym] || application[method_name.to_s]
          end
        end

        def resolve_reused_layers
          map = context[:reused_layers] || context['reused_layers']
          return {} unless map.is_a?(Hash)

          map.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = v.to_s
          end
        end

        def freeze_hash(hash)
          return {}.freeze if hash.nil?

          hash.each_with_object({}) do |(k, v), memo|
            memo[k.to_s] = v
          end.freeze
        end

        def extract_vpc_id_from_sg(sg)
          if sg.respond_to?(:vpc_id)
            sg.vpc_id
          elsif sg.is_a?(Hash)
            sg[:vpc_id] || sg['vpc_id']
          end
        end

        def resolve_vpc_param_key(v_id)
          if v_id.is_a?(Hash) && v_id['Ref']
            v_id['Ref'].to_s
          elsif v_id.respond_to?(:name) || v_id.is_a?(Symbol)
            name = v_id.respond_to?(:name) ? v_id.name : v_id
            LogicalId.pascalize(name)
          elsif v_id.is_a?(String) && !v_id.start_with?('vpc-')
            v_id
          end
        end

        def resolve_sns_topic_param_key(action)
          return nil if action.nil?

          if action.is_a?(Hash)
            return action['Ref'].to_s if action['Ref']
            return LogicalId.pascalize(action[:ref] || action['ref']) if action[:ref] || action['ref']

            nil
          elsif action.respond_to?(:name) || action.is_a?(Symbol)
            name = action.respond_to?(:name) ? action.name : action
            LogicalId.pascalize(name)
          elsif action.is_a?(String)
            str = action.strip
            return nil if str.start_with?('arn:')

            str
          end
        end

        def resolve_s3_bucket_param_key(bucket)
          return nil if bucket.nil?

          if bucket.is_a?(Hash)
            return bucket['Ref'].to_s if bucket['Ref']
            return bucket[:Ref].to_s if bucket[:Ref]
            return LogicalId.pascalize(bucket[:ref] || bucket['ref']) if bucket[:ref] || bucket['ref']

            nil
          elsif !bucket.is_a?(Symbol) && bucket.respond_to?(:name)
            LogicalId.pascalize(bucket.name)
          end
        end

        def resolve_subscription_destination_param_key(dest)
          return nil if dest.nil?

          if dest.is_a?(Hash) && dest['Ref']
            dest['Ref'].to_s
          elsif dest.is_a?(String)
            str = dest.strip
            return nil if str.start_with?('arn:aws:')

            str
          end
        end

        def resolve_subscription_role_param_key(role)
          return nil if role.nil?

          if role.is_a?(Hash) && role['Ref']
            role['Ref'].to_s
          elsif role.respond_to?(:name) || role.is_a?(Symbol)
            name = role.respond_to?(:name) ? role.name : role
            LogicalId.pascalize(name)
          elsif role.is_a?(String)
            str = role.strip
            return nil if str.start_with?('arn:aws:')

            str
          end
        end

        def resolve_async_destination_param_key(dest)
          return nil if dest.nil?

          case dest
          when Hash
            if dest['Ref']
              dest['Ref'].to_s
            elsif dest[:ref] || dest['ref']
              LogicalId.pascalize(dest[:ref] || dest['ref'])
            end
          when Symbol
            key = LogicalId.pascalize(dest)
            key.end_with?('Arn') ? key : "#{key}Arn"
          when String
            str = dest.strip
            return nil if str.start_with?('arn:aws:')

            str
          end
        end
      end
    end
  end
end
