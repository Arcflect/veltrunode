# frozen_string_literal: true

require 'yaml'

module Veltrunode
  module Compiler
    module CloudFormation
      class LayerVersionCompiler
        attr_reader :layer, :context

        class << self
          def compile(layer, **)
            new(layer, **).to_h
          end

          def to_yaml(layer, **)
            new(layer, **).to_yaml
          end

          def logical_id_for(layer_name)
            base = pascalize(layer_name)
            base = 'LayerVersion' if base.empty?
            base.end_with?('LayerVersion') ? base : "#{base}LayerVersion"
          end

          def pascalize(str)
            return '' if str.nil?

            str.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map do |part|
              part[0].upcase + part[1..]
            end.join
          end
        end

        def initialize(layer, context: {})
          @layer = layer
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(layer_name_source)
        end

        def resource_type
          'AWS::Lambda::LayerVersion'
        end

        def properties
          props = {
            'Content' => format_content
          }

          runtimes = format_compatible_runtimes
          props['CompatibleRuntimes'] = runtimes if runtimes && !runtimes.empty?

          archs = format_compatible_architectures
          props['CompatibleArchitectures'] = archs if archs && !archs.empty?

          desc = format_description
          props['Description'] = desc if desc

          lic = format_license_info
          props['LicenseInfo'] = lic if lic

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
          YAML.dump(to_h)
        end

        private

        def layer_name_source
          if layer.respond_to?(:name)
            layer.name
          elsif layer.is_a?(Hash)
            layer[:name] || layer['name']
          else
            layer.to_s
          end
        end

        def format_content
          return context[:content] if context[:content]
          return context['content'] if context['content']

          s3_bucket = context[:artifact_bucket] || context['artifact_bucket'] || { 'Ref' => 'ArtifactBucket' }
          s3_key = context[:s3_key] || context['s3_key'] || "artifacts/layers/#{layer_name_source}.zip"

          {
            'S3Bucket' => s3_bucket,
            'S3Key' => s3_key
          }
        end

        def format_compatible_runtimes
          runtimes = if layer.respond_to?(:compatible_runtimes)
                       layer.compatible_runtimes
                     elsif layer.is_a?(Hash)
                       layer[:compatible_runtimes] || layer['compatible_runtimes'] ||
                         layer[:runtimes] || layer['runtimes']
                     end
          return nil unless runtimes

          Array(runtimes).map(&:to_s).sort
        end

        def format_compatible_architectures
          archs = if layer.respond_to?(:architectures)
                    layer.architectures
                  elsif layer.is_a?(Hash)
                    layer[:architectures] || layer['architectures']
                  end
          return nil unless archs

          Array(archs).map(&:to_s).sort
        end

        def format_description
          if layer.respond_to?(:description)
            layer.description
          elsif layer.is_a?(Hash)
            layer[:description] || layer['description']
          end
        end

        def format_license_info
          lic = if layer.respond_to?(:license_metadata)
                  layer.license_metadata
                elsif layer.is_a?(Hash)
                  layer[:license_metadata] || layer['license_metadata'] ||
                    layer[:license_info] || layer['license_info']
                end
          return nil if lic.nil?

          lic.is_a?(Hash) ? lic[:license] || lic['license'] || lic.to_s : lic.to_s
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
