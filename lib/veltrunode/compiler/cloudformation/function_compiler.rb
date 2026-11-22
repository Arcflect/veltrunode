# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'lambda_insights'

module Veltrunode
  module Compiler
    module CloudFormation
      class FunctionCompiler
        attr_reader :function, :role, :code, :layer_map, :mount_map, :context, :depends_on

        class << self
          def compile(function, **)
            new(function, **).to_h
          end

          def to_yaml(function, **)
            new(function, **).to_yaml
          end

          def logical_id_for(logical_name)
            LogicalId.for_function(logical_name)
          end

          def pascalize(str)
            LogicalId.pascalize(str)
          end
        end

        def initialize(function, role: nil, code: nil, layer_map: {}, mount_map: {}, depends_on: nil, context: {})
          @function = function
          @role = role
          @code = code
          @layer_map = freeze_hash(layer_map)
          @mount_map = freeze_hash(mount_map)
          @context = freeze_hash(context)
          @depends_on = resolve_depends_on(depends_on)
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

          if image_function?
            props['PackageType'] = 'Image'
            if function.respond_to?(:image_config) && present?(function.image_config)
              props['ImageConfig'] = function.image_config
            end
          else
            props['Handler'] = function.handler if present?(function.handler)
            props['Runtime'] = function.runtime if present?(function.runtime)
          end

          props['Architectures'] = [function.architecture.to_s] if present?(function.architecture)

          props['MemorySize'] = function.memory.to_i if present?(function.memory)
          props['Timeout'] = function.timeout.to_i if present?(function.timeout)

          if present?(function.ephemeral_storage)
            props['EphemeralStorage'] = { 'Size' => function.ephemeral_storage.to_i }
          end

          env_vars = format_environment(function.environment)
          if function.respond_to?(:adot_enabled?) && function.adot_enabled? &&
             adot_supports_exec_wrapper? && !env_vars.key?('AWS_LAMBDA_EXEC_WRAPPER')
            env_vars['AWS_LAMBDA_EXEC_WRAPPER'] = '/opt/otel-instrument'
          end
          props['Environment'] = { 'Variables' => env_vars } unless env_vars.empty?

          if present?(function.vpc_reference)
            vpc_cfg = format_vpc_config(function.vpc_reference)
            props['VpcConfig'] = vpc_cfg if vpc_cfg && !vpc_cfg.empty?
          elsif present?(function.mounts)
            vpc_cfg = infer_vpc_config_from_mounts
            props['VpcConfig'] = vpc_cfg if vpc_cfg && !vpc_cfg.empty?
          end

          unless image_function?
            layers_to_attach = Array(function.layers).dup
            if function.respond_to?(:adot_enabled?) && function.adot_enabled?
              adot_arn = resolve_adot_layer_arn
              layers_to_attach << adot_arn if adot_arn
            end
            if function.respond_to?(:insights_enabled?) && function.insights_enabled?
              insights_arn = resolve_insights_layer_arn
              layers_to_attach << insights_arn if insights_arn
            end

            unless layers_to_attach.empty?
              layers_list = format_layers(layers_to_attach)
              props['Layers'] = layers_list unless layers_list.empty?
            end
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

          if function.respond_to?(:tracing_mode) && function.tracing_mode
            props['TracingConfig'] = { 'Mode' => function.tracing_mode }
          end

          deep_sort_keys(props)
        end

        def resource_definition
          res = {
            'Type' => resource_type,
            'Properties' => properties
          }
          res['DependsOn'] = depends_on.sort if present?(depends_on)
          deep_sort_keys(res)
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

        def resolve_depends_on(dep)
          return nil if dep == false

          if dep.nil?
            ["#{logical_id}LogGroup"]
          else
            Array(dep).map(&:to_s)
          end
        end

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
          unless vpc_ref.is_a?(Hash)
            str = vpc_ref.to_s
            if (vpc_ref.is_a?(String) || vpc_ref.is_a?(Symbol)) && str.start_with?('vpc-')
              raise ValidationError,
                    'vpc_reference must provide security_group_ids/subnet_ids; ' \
                    "VPC IDs (#{str}) are not supported for Lambda VpcConfig"
            end

            raise ValidationError,
                  'vpc_reference must be a Hash containing security_group_ids and subnet_ids for Lambda VpcConfig'
          end

          sg_ids = vpc_ref[:security_group_ids] || vpc_ref['security_group_ids'] || vpc_ref['SecurityGroupIds']
          if sg_ids.nil?
            sg_ref = vpc_ref[:security_group] || vpc_ref['security_group'] ||
                     vpc_ref[:security_groups] || vpc_ref['security_groups']
            sg_ids = sg_ref if sg_ref
          end

          sub_ids = vpc_ref[:subnet_ids] || vpc_ref['subnet_ids'] || vpc_ref['SubnetIds']
          if sub_ids.nil? || (sub_ids.respond_to?(:empty?) && sub_ids.empty?)
            mount_sub_ids = collect_mount_subnet_ids
            sub_ids = mount_sub_ids unless mount_sub_ids.empty?
          end

          cfg = {}
          if sg_ids.is_a?(Hash)
            cfg['SecurityGroupIds'] = sg_ids
          else
            explicit_sgs = sg_ids ? format_security_group_ids(sg_ids) : []
            mount_sgs = collect_mount_security_group_ids(include_context_sgs: explicit_sgs.empty?)
            combined_sgs = (explicit_sgs + mount_sgs).uniq
            cfg['SecurityGroupIds'] = combined_sgs unless combined_sgs.empty?
          end
          cfg['SubnetIds'] = format_subnet_ids(sub_ids) if sub_ids
          cfg
        end

        def infer_vpc_config_from_mounts
          sub_ids = collect_mount_subnet_ids
          return {} if sub_ids.empty?

          sg_ids = collect_mount_security_group_ids(include_context_sgs: true)
          return {} if sg_ids.empty?

          {
            'SecurityGroupIds' => sg_ids,
            'SubnetIds' => sub_ids
          }
        end

        def format_subnet_ids(sub_ids)
          return sub_ids if sub_ids.is_a?(Hash)

          Array(sub_ids).map do |sub|
            if sub.is_a?(Hash)
              ref_sym = sub[:ref] || sub['ref']
              ref_sym ? { 'Ref' => LogicalId.pascalize(ref_sym) } : sub
            elsif !sub.is_a?(Symbol) && sub.respond_to?(:name)
              { 'Ref' => LogicalId.pascalize(sub.name) }
            elsif sub.is_a?(Symbol)
              { 'Ref' => LogicalId.pascalize(sub) }
            else
              sub.to_s
            end
          end
        end

        def collect_mount_security_group_ids(include_context_sgs: true)
          sgs = []
          mounts_list = function.respond_to?(:mounts) ? Array(function.mounts) : []
          mounted_names = []

          mounts_list.each do |mount_entry|
            if mount_entry.is_a?(Hash)
              inline_sg = mount_entry[:security_group_ids] || mount_entry['security_group_ids'] ||
                          mount_entry[:security_group_id] || mount_entry['security_group_id']
              sgs.concat(format_security_group_ids(inline_sg)) if inline_sg
            end

            m_name = extract_mount_entry_name(mount_entry)
            mounted_names << m_name if m_name
            mount_obj = if mount_entry.respond_to?(:security_group_helper)
                          mount_entry
                        elsif m_name
                          mount_map[m_name]
                        end
            next unless mount_obj

            if mount_obj.respond_to?(:security_group_helper?) && mount_obj.security_group_helper?
              helper = mount_obj.security_group_helper
              sg_name = helper.respond_to?(:symbolic_name) ? helper.symbolic_name : m_name
              sgs << { 'Ref' => LogicalId.for_lambda_security_group(sg_name) }
            end

            next unless include_context_sgs && mount_obj.respond_to?(:vpc_expectations) &&
                        mount_obj.vpc_expectations.is_a?(Hash)

            exp_sg = mount_obj.vpc_expectations['security_group_ids'] ||
                     mount_obj.vpc_expectations[:security_group_ids] ||
                     mount_obj.vpc_expectations['security_group_id'] ||
                     mount_obj.vpc_expectations[:security_group_id]
            sgs.concat(format_security_group_ids(exp_sg)) if exp_sg
          end

          sgs_in_context = context[:security_groups] || context['security_groups']
          if include_context_sgs && sgs_in_context
            known_mount_names = mount_map.keys.map(&:to_s)
            all_ctx_sgs = Array(sgs_in_context)
            relevant_sgs = all_ctx_sgs.select do |sg|
              sg_name = (sg.respond_to?(:symbolic_name) ? sg.symbolic_name : sg).to_s
              !known_mount_names.include?(sg_name) || mounted_names.include?(sg_name)
            end
            relevant_sgs = all_ctx_sgs if relevant_sgs.empty?
            relevant_sgs.each do |sg|
              sg_name = sg.respond_to?(:symbolic_name) ? sg.symbolic_name : sg
              sgs << { 'Ref' => LogicalId.for_lambda_security_group(sg_name) }
            end
          end

          sgs.uniq
        end

        def collect_mount_subnet_ids
          subs = []
          mounts_list = function.respond_to?(:mounts) ? Array(function.mounts) : []
          mounts_list.each do |mount_entry|
            m_name = extract_mount_entry_name(mount_entry)
            mount_obj = if mount_entry.respond_to?(:vpc_expectations) || mount_entry.respond_to?(:subnet_ids)
                          mount_entry
                        elsif m_name
                          mount_map[m_name]
                        end
            next unless mount_obj

            raw_subs = if mount_obj.respond_to?(:subnet_ids) && !Array(mount_obj.subnet_ids).empty?
                         mount_obj.subnet_ids
                       elsif mount_obj.respond_to?(:vpc_expectations) && mount_obj.vpc_expectations.is_a?(Hash)
                         mount_obj.vpc_expectations['subnet_ids'] || mount_obj.vpc_expectations[:subnet_ids]
                       end
            subs.concat(format_subnet_ids(raw_subs)) if raw_subs
          end
          subs.uniq
        end

        def extract_mount_entry_name(mount_entry)
          if mount_entry.respond_to?(:symbolic_name)
            mount_entry.symbolic_name.to_s
          elsif mount_entry.respond_to?(:name)
            mount_entry.name.to_s
          elsif mount_entry.is_a?(Hash)
            (mount_entry[:name] || mount_entry['name'] ||
             mount_entry[:symbolic_name] || mount_entry['symbolic_name'] ||
             mount_entry[:mount] || mount_entry['mount'])&.to_s
          else
            mount_entry.to_s.split(':', 2).first
          end
        end

        def format_security_group_ids(sg_ids)
          return sg_ids if sg_ids.is_a?(Hash)

          Array(sg_ids).map do |id|
            if id.is_a?(Hash)
              id
            elsif id.respond_to?(:name) || id.is_a?(Symbol)
              name = id.respond_to?(:name) ? id.name : id
              base = LogicalId.pascalize(name)
              ref_name = base.end_with?('SecurityGroup') ? base : "#{base}LambdaSecurityGroup"
              { 'Ref' => ref_name }
            elsif id.to_s.end_with?('SecurityGroup') && !id.to_s.start_with?('sg-')
              { 'Ref' => id.to_s }
            else
              id.to_s
            end
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
              base = self.class.pascalize(layer_name)
              base = 'LayerVersion' if base.empty?
              ref_name = base.end_with?('LayerVersion') ? base : "#{base}LayerVersion"
              { 'Ref' => ref_name }
            end
          end
        end

        def format_file_system_configs(mounts_array)
          if mounts_array && !mounts_array.empty? &&
             (function.vpc_reference.nil? || function.vpc_reference.empty?) &&
             infer_vpc_config_from_mounts.empty?
            raise ValidationError,
                  "Function '#{function.logical_name}' has EFS mounts configured but does not specify a VpcConfig " \
                  '(vpc_reference). Lambda requires VpcConfig to mount EFS.'
          end

          configs = Array(mounts_array).map do |mount_entry|
            if mount_entry.respond_to?(:access_point_source) && mount_entry.respond_to?(:local_path)
              {
                'Arn' => format_arn_or_ref(mount_entry.access_point_source),
                'LocalMountPath' => mount_entry.local_path
              }
            elsif mount_entry.is_a?(Hash)
              mount_name = mount_entry[:name] || mount_entry['name'] ||
                           mount_entry[:symbolic_name] || mount_entry['symbolic_name'] ||
                           mount_entry[:mount] || mount_entry['mount']
              raw_arn = mount_entry[:arn] || mount_entry['arn'] || mount_entry['Arn'] ||
                        mount_entry[:access_point_source] || mount_entry['access_point_source']

              if raw_arn.nil? && mount_name && mount_map.key?(mount_name.to_s)
                m = mount_map[mount_name.to_s]
                raw_arn = m.respond_to?(:access_point_source) ? m.access_point_source : m
              end

              arn = raw_arn || mount_name
              mapped = mount_map[mount_name.to_s]
              mapped_local = mapped.local_path if mapped.respond_to?(:local_path)
              local_path = mount_entry[:local_path] || mount_entry['local_path'] ||
                           mount_entry['LocalMountPath'] || mount_entry[:local_mount_path] ||
                           mount_entry['local_mount_path'] ||
                           mapped_local ||
                           (mount_name ? "/mnt/#{mount_name}" : nil)

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
              elsif mount_name.start_with?('arn:')
                {
                  'Arn' => mount_name,
                  'LocalMountPath' => mount_path || '/mnt/data'
                }
              else
                ref_name = "#{self.class.pascalize(mount_name)}AccessPoint"
                {
                  'Arn' => { 'Fn::GetAtt' => [ref_name, 'Arn'] },
                  'LocalMountPath' => mount_path || "/mnt/#{mount_name}"
                }
              end
            end
          end

          validate_unique_local_mount_paths!(configs)
          configs
        end

        def validate_unique_local_mount_paths!(configs)
          paths = configs.map { |c| c.is_a?(Hash) ? (c['LocalMountPath'] || c[:local_mount_path]) : nil }.compact
          counts = Hash.new(0)
          paths.each { |p| counts[p.to_s] += 1 }
          duplicates = counts.select { |_p, c| c > 1 }.keys
          return if duplicates.empty?

          raise ValidationError,
                "Function '#{function.logical_name}' has duplicate EFS mount local_path: #{duplicates.join(', ')}"
        end

        def format_arn_or_ref(val)
          return val if val.is_a?(Hash)

          val_str = val.to_s
          if val_str.start_with?('arn:')
            val_str
          elsif val.respond_to?(:name)
            { 'Fn::GetAtt' => ["#{self.class.pascalize(val.name)}AccessPoint", 'Arn'] }
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

        def image_function?
          function.respond_to?(:image?) && function.image?
        end

        def format_code
          return code if code

          artifact_entry = resolve_artifact_context(function.logical_name)
          return artifact_entry if artifact_entry

          return format_image_code if image_function?

          {
            'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
            'S3Key' => "artifacts/functions/#{function.logical_name}.zip"
          }
        end

        def format_image_code
          uri = function.respond_to?(:image_uri) ? function.image_uri : nil
          tag = function.respond_to?(:image_tag) ? function.image_tag : nil

          if uri
            if !uri.is_a?(Symbol) && uri.respond_to?(:name)
              return { 'ImageUri' => { 'Ref' => LogicalId.pascalize(uri.name.to_s) } }
            elsif uri.is_a?(Symbol)
              return { 'ImageUri' => { 'Ref' => LogicalId.pascalize(uri.to_s) } }
            elsif uri.is_a?(Hash)
              return { 'ImageUri' => deep_stringify_keys(uri) }
            else
              uri_str = uri.to_s.strip
              if tag && !uri_str.include?('@') && !uri_str.split('/').last.to_s.include?(':')
                uri_str = "#{uri_str}:#{tag}"
              end
              return { 'ImageUri' => uri_str }
            end
          end

          repo = (function.respond_to?(:image_repository) && function.image_repository) || function.logical_name
          resolved_tag = tag || 'latest'
          if repo.include?('.dkr.ecr.') || (repo.include?('/') && repo.split('/').first.to_s.include?('.'))
            image_uri = if repo.include?('@') || repo.split('/').last.to_s.include?(':')
                          repo
                        else
                          "#{repo}:#{resolved_tag}"
                        end
            { 'ImageUri' => image_uri }
          else
            {
              'ImageUri' => {
                'Fn::Sub' => "${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/#{repo}:#{resolved_tag}"
              }
            }
          end
        end

        def resolve_artifact_context(name)
          map = context[:artifact_map] || context['artifact_map']
          return nil unless map.is_a?(Hash)

          entry = map[name] || map[name.to_sym]
          return nil unless entry.is_a?(Hash)

          image_uri_val = entry[:image_uri] || entry['image_uri'] || entry['ImageUri']
          return { 'ImageUri' => image_uri_val } if image_uri_val

          bucket_val = entry[:bucket] || entry['bucket'] || entry[:s3_bucket] || entry['S3Bucket']
          key_val = entry[:key] || entry['key'] || entry[:s3_key] || entry['S3Key']
          return nil unless bucket_val && key_val

          {
            'S3Bucket' => bucket_val,
            'S3Key' => key_val
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

        def resolve_adot_layer_arn
          return function.adot_layer_arn if function.respond_to?(:adot_layer_arn) && function.adot_layer_arn

          ctx_adot = context[:adot_layer_arn] || context['adot_layer_arn']
          return ctx_adot if ctx_adot

          runtime_str = function.runtime.to_s.downcase
          arch_str = function.architecture.to_s == 'arm64' ? 'arm64' : 'amd64'

          layer_name = if runtime_str.start_with?('node')
                         "aws-otel-nodejs-#{arch_str}-ver-1-18-0:1"
                       elsif runtime_str.start_with?('python')
                         "aws-otel-python-#{arch_str}-ver-1-20-0:1"
                       elsif runtime_str.start_with?('java')
                         "aws-otel-java-wrapper-#{arch_str}-ver-1-32-0:1"
                       else
                         "aws-otel-collector-#{arch_str}-ver-0-84-0:1"
                       end

          { 'Fn::Sub' => "arn:aws:lambda:${AWS::Region}:901920570468:layer:#{layer_name}" }
        end

        def adot_supports_exec_wrapper?
          rt = function.runtime.to_s.downcase
          rt.start_with?('node') || rt.start_with?('python') || rt.start_with?('java')
        end

        def resolve_insights_layer_arn
          LambdaInsights.resolve_layer_arn(function, context: context)
        end
      end
    end
  end
end
