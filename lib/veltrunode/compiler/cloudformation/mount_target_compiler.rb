# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::EFS::MountTarget リソース群のコンパイラ
      class MountTargetCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(mount_name, subnet_identifier = nil)
            LogicalId.for_mount_target(mount_name, subnet_identifier)
          end

          def logical_ids_for(mount)
            new(mount).logical_ids
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

        def resource_type
          'AWS::EFS::MountTarget'
        end

        def file_system_logical_id
          LogicalId.for_file_system(mount_name)
        end

        def efs_security_group_logical_id
          sg_name = if mount.respond_to?(:security_group_helper) && mount.security_group_helper
                      mount.security_group_helper.symbolic_name
                    else
                      mount_name
                    end
          LogicalId.for_efs_security_group(sg_name)
        end

        def logical_ids
          extract_subnet_ids.map do |sub|
            self.class.logical_id_for(mount_name, sub)
          end
        end

        def to_h
          resources = {}
          fs_id = resolve_file_system_id
          sgs = resolve_security_groups

          extract_subnet_ids.each do |sub|
            mt_id = self.class.logical_id_for(mount_name, sub)
            resources[mt_id] = {
              'Type' => resource_type,
              'Properties' => {
                'FileSystemId' => fs_id,
                'SecurityGroups' => sgs,
                'SubnetId' => format_ref_or_str(sub)
              }
            }
          end

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
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

        def resolve_file_system_id
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

        def extract_subnet_ids
          subs = if mount.respond_to?(:subnet_ids) && mount.subnet_ids && !mount.subnet_ids.empty?
                   mount.subnet_ids
                 elsif mount.respond_to?(:managed_file_system) && mount.managed_file_system&.subnet_ids
                   mount.managed_file_system.subnet_ids
                 elsif mount.is_a?(Hash)
                   mount[:subnet_ids] || mount['subnet_ids'] || mount[:subnets] || mount['subnets'] ||
                     extract_hash_mfs_field(mount, :subnet_ids, 'subnet_ids')
                 end
          Array(subs).flatten.compact
        end

        def resolve_security_groups
          explicit = extract_security_group_ids.map { |sg| format_ref_or_str(sg) }
          has_sg_helper = (mount.respond_to?(:security_group_helper?) && mount.security_group_helper?) ||
                          explicit.empty?
          sgs = []
          sgs << { 'Ref' => efs_security_group_logical_id } if has_sg_helper
          sgs.concat(explicit)
          sgs.uniq
        end

        def extract_security_group_ids
          sgs = if mount.respond_to?(:security_group_ids) &&
                   mount.security_group_ids && !mount.security_group_ids.empty?
                  mount.security_group_ids
                elsif mount.respond_to?(:managed_file_system) && mount.managed_file_system&.security_group_ids
                  mount.managed_file_system.security_group_ids
                elsif mount.is_a?(Hash)
                  mount[:security_group_ids] || mount['security_group_ids'] ||
                    mount[:security_groups] || mount['security_groups'] ||
                    extract_hash_mfs_field(mount, :security_group_ids, 'security_group_ids')
                end
          Array(sgs).flatten.compact
        end

        def extract_hash_mfs_field(hash, sym_key, str_key)
          mfs = hash[:managed_file_system] || hash['managed_file_system']
          return mfs.public_send(sym_key) if mfs.respond_to?(sym_key)
          return mfs[sym_key] || mfs[str_key] if mfs.is_a?(Hash)

          nil
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
