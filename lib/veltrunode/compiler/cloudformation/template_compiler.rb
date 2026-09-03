# frozen_string_literal: true

require 'fileutils'
require 'yaml'
require_relative 'function_compiler'
require_relative 'layer_version_compiler'
require_relative 'log_group_compiler'
require_relative 'queue_compiler'
require_relative 'role_compiler'
require_relative 'schedule_compiler'
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
          @context = freeze_hash(context)
          @parameters = freeze_hash(parameters)
          @description = description
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
          content = to_yaml
          FileUtils.mkdir_p(File.dirname(output_path))
          File.write(output_path, content)
          to_h
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

          # Include explicitly specified parameters
          parameters.each do |k, v|
            param_def = if v.is_a?(Hash)
                          v
                        else
                          { 'Type' => 'String', 'Default' => v.to_s }
                        end
            params[k.to_s] = param_def
          end

          # Include context parameters
          ctx_params = context[:parameters] || context['parameters']
          if ctx_params.is_a?(Hash)
            ctx_params.each do |k, v|
              params[k.to_s] = v.is_a?(Hash) ? v : { 'Type' => 'String', 'Default' => v.to_s }
            end
          end

          deep_sort_keys(params)
        end

        def format_resources
          resources = {}

          # 1. Compile Layers
          layer_nodes = extract_collection(:layers)
          layer_nodes.each do |layer|
            layer_res = LayerVersionCompiler.compile(layer, context: context)
            resources.merge!(layer_res)
          end

          # 2. Compile Queues (e.g. newly created DLQs referenced in schedules)
          generated_queues = discover_generated_queues
          generated_queues.each do |q_name|
            queue_res = QueueCompiler.compile(q_name, context: context)
            resources.merge!(queue_res)
          end

          # 3. Compile Functions (Role, LogGroup, Function with DependsOn)
          fn_nodes = extract_collection(:functions)
          local_layer_names = layer_nodes.map { |l| extract_name(l) }.compact

          fn_nodes.each do |fn|
            # Lambda Execution Role
            role_res = RoleCompiler.compile_lambda_role(fn, context: context)
            resources.merge!(role_res)

            # CloudWatch Log Group
            log_res = LogGroupCompiler.compile(
              fn,
              defaults: resolve_function_defaults,
              context: context
            )
            resources.merge!(log_res)

            # Lambda Function with Graph-aware DependsOn
            depends_on = resolve_function_dependencies(fn, local_layer_names)
            fn_res = FunctionCompiler.compile(
              fn,
              context: context,
              depends_on: depends_on
            )
            resources.merge!(fn_res)
          end

          # 4. Compile Schedules (Role, Schedule)
          sched_nodes = extract_collection(:schedules)
          sched_nodes.each do |sched|
            role_res = RoleCompiler.compile_scheduler_role(sched, context: context)
            resources.merge!(role_res)

            sched_res = ScheduleCompiler.compile(sched, context: context)
            resources.merge!(sched_res)
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
          layer_nodes = extract_collection(:layers)
          layer_nodes.each do |layer|
            layer_name = extract_name(layer)
            layer_id = LayerVersionCompiler.logical_id_for(layer_name)

            outputs["#{layer_id}Arn"] = {
              'Description' => "ARN of #{layer_name} Lambda layer version",
              'Value' => { 'Ref' => layer_id },
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

          deep_sort_keys(outputs)
        end

        def resolve_function_dependencies(fn, local_layer_names)
          fn_name = extract_name(fn)
          fn_id = FunctionCompiler.logical_id_for(fn_name)

          deps = ["#{fn_id}LogGroup"]

          # If attached layers are locally defined in this application, add their LayerVersion logical IDs
          attached_layers = fn.respond_to?(:layers) ? Array(fn.layers) : []
          attached_layers.each do |l_ref|
            l_name = extract_name(l_ref)
            deps << LayerVersionCompiler.logical_id_for(l_name) if local_layer_names.include?(l_name)
          end

          deps.uniq.sort
        end

        def discover_generated_queues
          sched_nodes = extract_collection(:schedules)
          queues = []

          sched_nodes.each do |sched|
            dlq = sched.respond_to?(:dlq) ? sched.dlq : nil
            next if dlq.nil?
            next if dlq.is_a?(Hash)

            dlq_str = dlq.to_s.strip
            next if dlq_str.empty? || dlq_str.start_with?('arn:')

            queues << dlq_str
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
          elsif item.respond_to?(:name)
            item.name
          elsif item.is_a?(Hash)
            item[:logical_name] || item['logical_name'] || item[:name] || item['name']
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
