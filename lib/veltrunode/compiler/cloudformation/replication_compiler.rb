# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative '../../model/managed_access_point'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::EFS::ReplicationConfiguration リソースのコンパイラ
      class ReplicationCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(name)
            LogicalId.for_replication_configuration(name)
          end

          def file_system_logical_id_for(name)
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

        def file_system_logical_id
          self.class.file_system_logical_id_for(mount_name)
        end

        def resource_type
          'AWS::EFS::ReplicationConfiguration'
        end

        def to_h
          rep = normalized_replication
          return {} if rep.nil? || rep.empty?

          deep_sort_keys(
            logical_id => {
              'Type' => resource_type,
              'Properties' => properties(rep)
            }
          )
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def properties(rep = normalized_replication)
          return {} if rep.nil? || rep.empty?

          {
            'Destinations' => [build_destination(rep)],
            'SourceFileSystemId' => resolve_source_file_system_id
          }
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

        def normalized_replication
          raw = extract_raw_replication
          return nil if raw.nil?

          Model::ManagedAccessPoint.normalize_replication_config(raw)
        end

        def extract_raw_replication
          if mount.respond_to?(:replication) && mount.replication
            mount.replication
          elsif mount.respond_to?(:managed_access_point) && mount.managed_access_point&.replication
            mount.managed_access_point.replication
          elsif mount.respond_to?(:managed_file_system) && mount.managed_file_system&.replication
            mount.managed_file_system.replication
          elsif mount.is_a?(Hash)
            mount[:replication] || mount['replication'] ||
              mount[:replication_configuration] || mount['replication_configuration'] ||
              extract_hash_ap_replication(mount)
          end
        end

        def extract_hash_ap_replication(hash)
          ap = hash[:managed_access_point] || hash['managed_access_point'] ||
               hash[:managed_file_system] || hash['managed_file_system']
          return ap.replication if ap.respond_to?(:replication)
          return ap[:replication] || ap['replication'] if ap.is_a?(Hash)

          nil
        end

        def resolve_source_file_system_id
          raw_fs = extract_file_system_id
          return { 'Ref' => file_system_logical_id } if raw_fs.nil?

          format_ref_or_str(raw_fs)
        end

        def extract_file_system_id
          if mount.respond_to?(:managed_access_point) && mount.managed_access_point&.file_system_id
            mount.managed_access_point.file_system_id
          elsif mount.respond_to?(:file_system_id) && mount.file_system_id
            mount.file_system_id
          elsif mount.is_a?(Hash)
            mount[:file_system_id] || mount['file_system_id']
          end
        end

        def build_destination(rep)
          dest = {}
          dest['Region'] = rep['destination_region'] if rep['destination_region']
          dest['KmsKeyId'] = format_ref_or_str(rep['kms_key_id']) if rep['kms_key_id']
          dest['AvailabilityZoneName'] = rep['availability_zone_name'] if rep['availability_zone_name']
          dest['FileSystemId'] = format_ref_or_str(rep['file_system_id']) if rep['file_system_id']
          dest['RoleArn'] = format_ref_or_str(rep['role_arn']) if rep['role_arn']
          dest
        end

        def format_ref_or_str(val)
          if val.is_a?(Hash)
            ref_sym = val[:ref] || val['ref']
            return { 'Ref' => LogicalId.pascalize(ref_sym) } if ref_sym

            ref_lit = val[:Ref] || val['Ref']
            return { 'Ref' => ref_lit.to_s } if ref_lit

            return val
          end

          return { 'Ref' => LogicalId.pascalize(val.name) } if !val.is_a?(Symbol) && val.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(val) } if val.is_a?(Symbol)

          val.to_s
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
