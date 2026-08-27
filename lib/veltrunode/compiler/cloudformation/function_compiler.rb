# frozen_string_literal: true

require 'yaml'

module Veltrunode
  module Compiler
    module CloudFormation
      class FunctionCompiler
        attr_reader :function, :role, :code, :layer_map, :mount_map, :context

        class << self
          def compile(function, **)
            new(function, **).to_h
          end

          def to_yaml(function, **)
            new(function, **).to_yaml
          end

          def logical_id_for(logical_name)
            base = pascalize(logical_name)
            base = 'Function' if base.empty?
            base.end_with?('Function') ? base : "#{base}Function"
          end

          def pascalize(str)
            return '' if str.nil?

            str.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
              part[0].upcase + part[1..]
            end.join
          end
        end

        def initialize(function, role: nil, code: nil, layer_map: {}, mount_map: {}, context: {})
          @function = function
          @role = role
          @code = code
          @layer_map = freeze_hash(layer_map)
          @mount_map = freeze_hash(mount_map)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(function.logical_name)
        end

        def resource_type
          'AWS::Lambda::Function'
        end

        def properties
          props = {}

          props['FunctionName'] = function.logical_name if present?(function.logical_name)
          props['Handler'] = function.handler if present?(function.handler)
          props['Runtime'] = function.runtime if present?(function.runtime)

          props['Architectures'] = [function.architecture.to_s] if present?(function.architecture)

          props['MemorySize'] = function.memory.to_i if present?(function.memory)
          props['Timeout'] = function.timeout.to_i if present?(function.timeout)

          if present?(function.ephemeral_storage)
            props['EphemeralStorage'] = { 'Size' => function.ephemeral_storage.to_i }
          end

          if present?(function.environment)
            env_vars = format_environment(function.environment)
            props['Environment'] = { 'Variables' => env_vars } unless env_vars.empty?
          end

          if present?(function.vpc_reference)
            vpc_cfg = format_vpc_config(function.vpc_reference)
            props['VpcConfig'] = vpc_cfg if vpc_cfg && !vpc_cfg.empty?
          end

          if present?(function.layers)
            layers_list = format_layers(function.layers)
            props['Layers'] = layers_list unless layers_list.empty?
          end

          if present?(function.mounts)
            fs_configs = format_file_system_configs(function.mounts)
            props['FileSystemConfigs'] = fs_configs unless fs_configs.empty?
          end

          props['Role'] = format_role
          props['Code'] = format_code

          if present?(function.concurrency)
            conc = format_concurrency(function.concurrency)
            props['ReservedConcurrentExecutions'] = conc if conc
          end

          if present?(function.logging)
            log_cfg = format_logging(function.logging)
            props['LoggingConfig'] = log_cfg if log_cfg && !log_cfg.empty?
          end

          deep_sort_keys(props)
        end

        def resource_definition
          {
            'Type' => resource_type,
            'Properties' => properties
          }
        end

        def to_h
          deep_sort_keys({
                           logical_id => resource_definition
                         })
        end

        def to_yaml
          sorted_hash = to_h
          YAML.dump(sorted_hash)
        end

        private

        def present?(val)
          return false if val.nil?
          return !val.empty? if val.respond_to?(:empty?)

          !val.to_s.strip.empty?
        end

        def format_environment(env_hash)
          return {} unless env_hash.is_a?(Hash)

          env_hash.each_with_object({}) do |(k, v), memo|
            if v.respond_to?(:secret?) && v.secret?
              raise ValidationError, "SecretValue cannot be embedded into CloudFormation templates (env var '#{k}')"
            end

            memo[k.to_s] = v.is_a?(Hash) || v.is_a?(Array) ? v : v.to_s
          end
        end

        def format_vpc_config(vpc_ref)
          if vpc_ref.is_a?(Hash)
            sg_ids = vpc_ref[:security_group_ids] || vpc_ref['security_group_ids'] || vpc_ref['SecurityGroupIds']
            sub_ids = vpc_ref[:subnet_ids] || vpc_ref['subnet_ids'] || vpc_ref['SubnetIds']

            cfg = {}
            cfg['SecurityGroupIds'] = Array(sg_ids).map(&:to_s) if sg_ids
            cfg['SubnetIds'] = Array(sub_ids).map(&:to_s) if sub_ids
            cfg
          elsif vpc_ref.respond_to?(:name)
            { 'Ref' => self.class.pascalize(vpc_ref.name) }
          elsif vpc_ref.is_a?(Symbol) || vpc_ref.is_a?(String)
            str = vpc_ref.to_s
            if str.start_with?('vpc-')
              raise ValidationError,
                    'vpc_reference must provide security_group_ids/subnet_ids; ' \
                    "VPC IDs (#{str}) are not supported for Lambda VpcConfig"
            end

            { 'Ref' => self.class.pascalize(str) }

          else
            vpc_ref
          end
        end

        def format_layers(layers_array)
          Array(layers_array).map do |layer_entry|
            layer_name = layer_entry.respond_to?(:name) ? layer_entry.name.to_s : layer_entry.to_s

            if layer_map.key?(layer_name) || layer_map.key?(layer_entry)
              layer_map[layer_name] || layer_map[layer_entry]
            elsif layer_entry.is_a?(Hash)
              layer_entry
            elsif layer_name.start_with?('arn:')
              layer_name
            else
              ref_name = "#{self.class.pascalize(layer_name)}LayerVersion"
              { 'Ref' => ref_name }
            end
          end
        end

        def format_file_system_configs(mounts_array)
          Array(mounts_array).map do |mount_entry|
            if mount_entry.respond_to?(:access_point_source) && mount_entry.respond_to?(:local_path)
              {
                'Arn' => format_arn_or_ref(mount_entry.access_point_source),
                'LocalMountPath' => mount_entry.local_path
              }
            elsif mount_entry.is_a?(Hash)
              arn = mount_entry[:arn] || mount_entry['arn'] || mount_entry['Arn'] ||
                    mount_entry[:access_point_source] || mount_entry['access_point_source']
              local_path = mount_entry[:local_path] || mount_entry['local_path'] ||
                           mount_entry['LocalMountPath'] || mount_entry[:local_mount_path]
              {
                'Arn' => format_arn_or_ref(arn),
                'LocalMountPath' => local_path.to_s
              }
            else
              entry_str = mount_entry.to_s
              mount_name, mount_path = entry_str.include?(':') ? entry_str.split(':', 2) : [entry_str, nil]

              if mount_map.key?(mount_name)
                m = mount_map[mount_name]
                if m.respond_to?(:access_point_source) && m.respond_to?(:local_path)
                  {
                    'Arn' => format_arn_or_ref(m.access_point_source),
                    'LocalMountPath' => mount_path || m.local_path
                  }
                else
                  m
                end
              else
                ref_name = "#{self.class.pascalize(mount_name)}AccessPoint"
                {
                  'Arn' => { 'Fn::GetAtt' => [ref_name, 'Arn'] },
                  'LocalMountPath' => mount_path || "/mnt/#{mount_name}"
                }
              end
            end
          end
        end

        def format_arn_or_ref(val)
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

        def format_role
          return role if role

          {
            'Fn::GetAtt' => [
              "#{logical_id}Role",
              'Arn'
            ]
          }
        end

        def format_code
          return code if code

          {
            'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
            'S3Key' => "artifacts/functions/#{function.logical_name}.zip"
          }
        end

        def format_concurrency(conc)
          if conc.is_a?(Hash)
            (conc[:reserved] || conc['reserved'] ||
             conc[:reserved_concurrent_executions] || conc['reserved_concurrent_executions'])&.to_i
          else
            conc.to_i
          end
        end

        def format_logging(log_cfg)
          return {} unless log_cfg.is_a?(Hash)

          res = {}
          fmt = log_cfg[:format] || log_cfg['format'] || log_cfg['LogFormat']
          lvl = log_cfg[:level] || log_cfg['level'] || log_cfg['LogLevel']

          res['LogFormat'] = fmt.to_s if fmt
          res['LogLevel'] = lvl.to_s if lvl
          res
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
