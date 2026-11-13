# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative 'file_system_compiler'
require_relative 'backup_compiler'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::EFS::AccessPoint リソースのコンパイラ
      class AccessPointCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(name)
            LogicalId.for_access_point(name)
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
          'AWS::EFS::AccessPoint'
        end

        def to_h
          resources = {
            logical_id => {
              'Type' => resource_type,
              'Properties' => properties
            }
          }
          resources.merge!(FileSystemCompiler.compile(mount, context: context)) if file_system_configuration?
          resources.merge!(BackupCompiler.compile(mount, context: context)) if backup_configuration?

          deep_sort_keys(resources)
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def properties
          map = managed_access_point_data
          props = {
            'FileSystemId' => resolve_file_system_id(map)
          }

          posix = format_posix_user(map.posix_user)
          props['PosixUser'] = posix if posix

          root_dir = format_root_directory(map, posix)
          props['RootDirectory'] = root_dir if root_dir

          tags = format_tags(map.tags)
          props['AccessPointTags'] = tags if tags

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

        def managed_access_point_data
          data = if mount.respond_to?(:managed_access_point) && mount.managed_access_point
                   mount.managed_access_point
                 elsif mount.is_a?(Hash)
                   mount[:managed_access_point] || mount['managed_access_point']
                 end

          return data if data

          raise ValidationError, "Mount '#{mount_name}' does not have managed_access_point configuration"
        end

        def resolve_file_system_id(map)
          fs_id = if map.respond_to?(:file_system_id)
                    map.file_system_id
                  else
                    map[:file_system_id] || map['file_system_id']
                  end
          return { 'Ref' => file_system_logical_id } if fs_id.nil?
          return { 'Ref' => LogicalId.pascalize(fs_id.name) } if fs_id.respond_to?(:name)

          fs_id
        end

        def file_system_configuration?
          return true if mount.respond_to?(:file_system_configuration?) && mount.file_system_configuration?
          return true if mount.respond_to?(:lifecycle_policies?) && mount.lifecycle_policies?

          map = managed_access_point_data
          return true if map.respond_to?(:file_system_configuration?) && map.file_system_configuration?
          return true if map.respond_to?(:lifecycle_policies?) && map.lifecycle_policies?

          false
        end
        alias lifecycle_policies? file_system_configuration?

        def backup_configuration?
          return true if mount.respond_to?(:backup?) && mount.backup?

          map = managed_access_point_data
          return true if map.respond_to?(:backup?) && map.backup?

          false
        end

        def format_posix_user(posix_user)
          return nil if posix_user.nil? || !posix_user.is_a?(Hash)

          uid = posix_user[:uid] || posix_user['uid']
          gid = posix_user[:gid] || posix_user['gid']
          return nil if uid.nil? || gid.nil?

          obj = {
            'Uid' => uid.to_s,
            'Gid' => gid.to_s
          }

          sec_gids = posix_user[:secondary_gids] || posix_user['secondary_gids']
          obj['SecondaryGids'] = Array(sec_gids).map(&:to_s) if sec_gids && !sec_gids.empty?

          obj
        end

        def format_root_directory(map, posix)
          path = map.root_directory_path
          creation_info = map.creation_info

          return nil if path.nil? && creation_info.nil?

          rd = {}
          rd['Path'] = path.to_s if path

          if creation_info
            rd['CreationInfo'] = {
              'OwnerUid' => (creation_info[:owner_uid] || creation_info['owner_uid']).to_s,
              'OwnerGid' => (creation_info[:owner_gid] || creation_info['owner_gid']).to_s,
              'Permissions' => (creation_info[:permissions] || creation_info['permissions'] || '0755').to_s
            }
          elsif posix && path && path != '/'
            rd['CreationInfo'] = {
              'OwnerUid' => posix['Uid'],
              'OwnerGid' => posix['Gid'],
              'Permissions' => '0755'
            }
          end

          rd
        end

        def format_tags(tags)
          return nil if tags.nil? || tags.empty?

          list = tags.map { |k, v| { 'Key' => k.to_s, 'Value' => v.to_s } }
          list.sort_by { |t| t['Key'] }
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
