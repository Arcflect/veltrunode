# frozen_string_literal: true

require_relative 'base_builder'
require_relative '../model/managed_access_point'

module Veltrunode
  module DSL
    class ManagedAccessPointBuilder < BaseBuilder
      def initialize(
        file_system_id = nil,
        root_directory: nil,
        path: nil,
        posix_user: nil,
        uid: nil,
        gid: nil,
        secondary_gids: nil,
        creation_info: nil,
        tags: nil
      )
        super()
        @file_system_id = file_system_id
        @root_directory_path = path || root_directory
        @posix_user = posix_user ? posix_user.dup : {}
        @posix_user[:uid] = uid if uid
        @posix_user[:gid] = gid if gid
        @posix_user[:secondary_gids] = secondary_gids if secondary_gids
        @creation_info = creation_info&.dup
        @tags = tags ? tags.dup : {}
        @local_path_val = nil
      end

      attr_reader :local_path_val

      def local_path(val = nil)
        return @local_path_val if val.nil?

        @local_path_val = val.to_s
      end

      def file_system_id(id = nil)
        return @file_system_id if id.nil?

        @file_system_id = id.to_s
      end
      alias fs_id file_system_id

      def root_directory(path_or_hash = nil, path: nil, creation_info: nil, owner_uid: nil, owner_gid: nil,
                         permissions: nil, &)
        if path_or_hash.is_a?(Hash)
          @root_directory_path = (path_or_hash[:path] || path_or_hash['path']).to_s
          ci = path_or_hash[:creation_info] || path_or_hash['creation_info']
          @creation_info = ci if ci
        elsif path_or_hash
          @root_directory_path = path_or_hash.to_s
        elsif path
          @root_directory_path = path.to_s
        end

        ci_hash = creation_info || {}
        ci_hash[:owner_uid] = owner_uid if owner_uid
        ci_hash[:owner_gid] = owner_gid if owner_gid
        ci_hash[:permissions] = permissions if permissions
        @creation_info = ci_hash unless ci_hash.empty?

        instance_eval(&) if block_given?
      end

      def path(val)
        @root_directory_path = val.to_s
      end

      def creation_info(owner_uid: nil, owner_gid: nil, permissions: nil)
        @creation_info ||= {}
        @creation_info[:owner_uid] = owner_uid if owner_uid
        @creation_info[:owner_gid] = owner_gid if owner_gid
        @creation_info[:permissions] = permissions if permissions
      end

      def posix_user(uid_or_hash = nil, uid: nil, gid: nil, secondary_gids: nil, &)
        if uid_or_hash.is_a?(Hash)
          @posix_user.merge!(uid_or_hash)
        elsif uid_or_hash
          @posix_user[:uid] = uid_or_hash
        end

        @posix_user[:uid] = uid if uid
        @posix_user[:gid] = gid if gid
        @posix_user[:secondary_gids] = secondary_gids if secondary_gids

        instance_eval(&) if block_given?
      end

      def uid(val)
        @posix_user[:uid] = val
      end

      def gid(val)
        @posix_user[:gid] = val
      end

      def secondary_gids(*gids)
        @posix_user[:secondary_gids] = gids.flatten
      end

      def tags(hash)
        @tags.merge!(hash)
      end

      def build
        posix = @posix_user.empty? ? nil : @posix_user
        Model::ManagedAccessPoint.new(
          file_system_id: @file_system_id,
          root_directory_path: @root_directory_path,
          posix_user: posix,
          creation_info: @creation_info,
          tags: @tags.empty? ? nil : @tags
        )
      end
    end
  end
end
