# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative '../../model/managed_access_point'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::EFS::FileSystem リソースのコンパイラ
      class FileSystemCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(name)
            LogicalId.for_file_system(name)
          end

          def pascalize(str)
            LogicalId.pascalize(str)
          end
        end

        def initialize(mount, options: {}, context: {})
          @mount = mount
          @options = freeze_hash(options)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(mount_name)
        end

        def resource_type
          'AWS::EFS::FileSystem'
        end

        def to_h
          deep_sort_keys(
            logical_id => {
              'Type' => resource_type,
              'Properties' => properties
            }
          )
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def properties
          props = {}
          policies = format_lifecycle_policies
          props['LifecyclePolicies'] = policies unless policies.empty?
          props
        end

        private

        def mount_name
          if mount.respond_to?(:symbolic_name)
            mount.symbolic_name
          elsif mount.respond_to?(:name)
            mount.name
          elsif mount.is_a?(Hash)
            mount[:symbolic_name] || mount['symbolic_name'] || mount[:name] || mount['name']
          else
            mount.to_s
          end
        end

        def format_lifecycle_policies
          raw = extract_lifecycle_policies
          Model::ManagedAccessPoint.to_cfn_lifecycle_policies(raw)
        end

        def extract_lifecycle_policies
          if mount.respond_to?(:lifecycle_policies) && mount.lifecycle_policies
            mount.lifecycle_policies
          elsif mount.respond_to?(:managed_access_point) && mount.managed_access_point&.lifecycle_policies
            mount.managed_access_point.lifecycle_policies
          elsif mount.is_a?(Hash)
            mount[:lifecycle_policies] || mount['lifecycle_policies'] ||
              mount[:lifecycle_policy] || mount['lifecycle_policy'] ||
              extract_from_hash_access_point(mount) ||
              mount
          end
        end

        def extract_from_hash_access_point(hash)
          ap = hash[:managed_access_point] || hash['managed_access_point']
          return ap.lifecycle_policies if ap.respond_to?(:lifecycle_policies)
          return ap[:lifecycle_policies] || ap['lifecycle_policies'] if ap.is_a?(Hash)

          nil
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
          (hash || {}).dup.freeze
        end
      end
    end
  end
end
