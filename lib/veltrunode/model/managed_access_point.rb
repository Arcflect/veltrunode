# frozen_string_literal: true

module Veltrunode
  module Model
    # 自動管理・生成される EFS アクセスポイントのモデル
    class ManagedAccessPoint
      FILE_SYSTEM_ID_PATTERN = /\Afs-[a-f0-9]+\z/i

      attr_reader :file_system_id,
                  :root_directory_path,
                  :posix_user,
                  :creation_info,
                  :tags

      def initialize(
        file_system_id:,
        root_directory_path: nil,
        posix_user: nil,
        creation_info: nil,
        tags: nil
      )
        resolved_root_path = root_directory_path ? root_directory_path.to_s.strip : '/'
        validate!(file_system_id:, root_directory_path: resolved_root_path, posix_user:, creation_info:)

        @file_system_id = file_system_id.to_s.strip.freeze
        @root_directory_path = resolved_root_path.freeze
        @posix_user = normalize_posix_user(posix_user)
        @creation_info = normalize_creation_info(creation_info)
        @tags = tags ? freeze_hash(tags) : {}.freeze

        freeze
      end

      def uid
        @posix_user&.fetch('uid', nil)
      end

      def gid
        @posix_user&.fetch('gid', nil)
      end

      def root_directory
        @root_directory_path
      end

      private

      def validate!(file_system_id:, root_directory_path:, posix_user:, creation_info:)
        validate_file_system_id!(file_system_id)
        validate_root_directory_path!(root_directory_path) if root_directory_path
        validate_posix_user!(posix_user) if posix_user
        validate_creation_info!(creation_info) if creation_info
      end

      def validate_file_system_id!(id)
        raise ValidationError, 'ManagedAccessPoint file_system_id is required' if id.nil? || id.to_s.strip.empty?

        id_str = id.to_s.strip
        return if id.is_a?(Hash) # CFN Ref / Fn::GetAtt 等を許容

        return if FILE_SYSTEM_ID_PATTERN.match?(id_str)

        raise ValidationError, "Invalid EFS file_system_id '#{id_str}'. Must match fs-[a-f0-9]+"
      end

      def validate_root_directory_path!(path)
        path_str = path.to_s.strip
        return if path_str.start_with?('/')

        raise ValidationError, "ManagedAccessPoint root_directory_path '#{path_str}' must start with '/'"
      end

      def validate_posix_user!(user)
        return unless user.is_a?(Hash)

        uid = user[:uid] || user['uid']
        gid = user[:gid] || user['gid']

        raise ValidationError, 'ManagedAccessPoint posix_user requires uid' if uid.nil?
        raise ValidationError, 'ManagedAccessPoint posix_user requires gid' if gid.nil?

        uid_i = begin
          Integer(uid)
        rescue StandardError
          nil
        end
        gid_i = begin
          Integer(gid)
        rescue StandardError
          nil
        end
        if uid_i.nil? || uid_i.negative?
          raise ValidationError, "ManagedAccessPoint posix_user uid must be a non-negative integer: '#{uid}'"
        end
        return unless gid_i.nil? || gid_i.negative?

        raise ValidationError, "ManagedAccessPoint posix_user gid must be a non-negative integer: '#{gid}'"
      end

      def validate_creation_info!(info)
        return unless info.is_a?(Hash)

        owner_uid = info[:owner_uid] || info['owner_uid']
        owner_gid = info[:owner_gid] || info['owner_gid']
        permissions = info[:permissions] || info['permissions']

        if owner_uid.nil? || owner_gid.nil?
          raise ValidationError, 'ManagedAccessPoint creation_info requires owner_uid and owner_gid'
        end
        raise ValidationError, 'ManagedAccessPoint creation_info requires permissions' if permissions.nil?

        uid_i = begin
          Integer(owner_uid)
        rescue StandardError
          nil
        end
        gid_i = begin
          Integer(owner_gid)
        rescue StandardError
          nil
        end
        if uid_i.nil? || uid_i.negative?
          raise ValidationError,
                "ManagedAccessPoint creation_info owner_uid must be a non-negative integer: '#{owner_uid}'"
        end
        return unless gid_i.nil? || gid_i.negative?

        raise ValidationError,
              "ManagedAccessPoint creation_info owner_gid must be a non-negative integer: '#{owner_gid}'"
      end

      def normalize_posix_user(user)
        return nil if user.nil? || !user.is_a?(Hash)

        uid_raw = user[:uid] || user['uid']
        gid_raw = user[:gid] || user['gid']
        uid_val = begin
          Integer(uid_raw)
        rescue StandardError
          uid_raw.to_s
        end
        gid_val = begin
          Integer(gid_raw)
        rescue StandardError
          gid_raw.to_s
        end

        hash = {
          'uid' => uid_val,
          'gid' => gid_val
        }
        sec_gids = user[:secondary_gids] || user['secondary_gids']
        if sec_gids
          hash['secondary_gids'] = Array(sec_gids).map do |g|
            Integer(g)
          rescue StandardError
            g.to_s
          end.freeze
        end
        hash.freeze
      end

      def normalize_creation_info(info)
        return nil if info.nil? || !info.is_a?(Hash)

        owner_uid_raw = info[:owner_uid] || info['owner_uid']
        owner_gid_raw = info[:owner_gid] || info['owner_gid']
        owner_uid_val = begin
          Integer(owner_uid_raw)
        rescue StandardError
          owner_uid_raw.to_s
        end
        owner_gid_val = begin
          Integer(owner_gid_raw)
        rescue StandardError
          owner_gid_raw.to_s
        end

        perm_raw = info[:permissions] || info['permissions']
        perm_str = if perm_raw.is_a?(Integer)
                     perm_raw.to_s.start_with?('0') ? perm_raw.to_s : "0#{perm_raw}"
                   else
                     str = perm_raw.to_s.strip
                     str.start_with?('0') ? str : "0#{str}"
                   end

        {
          'owner_uid' => owner_uid_val,
          'owner_gid' => owner_gid_val,
          'permissions' => perm_str.freeze
        }.freeze
      end

      def freeze_hash(hash)
        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = v.to_s.freeze
        end.freeze
      end
    end
  end
end
