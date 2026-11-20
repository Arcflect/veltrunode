# frozen_string_literal: true

require_relative 'managed_access_point'

module Veltrunode
  module Model
    # EFS ファイルシステム本体・マウントターゲット・削除保護を管理するモデル (Mode 3: Fully Managed)
    class ManagedFileSystem
      SUBNET_ID_PATTERN = /\Asubnet-[a-f0-9]+\z/i
      VPC_ID_PATTERN = /\Avpc-[a-f0-9]+\z/i
      SG_ID_PATTERN = /\Asg-[a-f0-9]+\z/i

      DELETION_POLICY_MAP = {
        'retain' => 'Retain',
        'delete' => 'Delete',
        'snapshot' => 'Snapshot',
        'retain_except_on_create' => 'RetainExceptOnCreate',
        'retainexceptoncreate' => 'RetainExceptOnCreate'
      }.freeze

      UPDATE_REPLACE_POLICY_MAP = {
        'retain' => 'Retain',
        'delete' => 'Delete',
        'snapshot' => 'Snapshot'
      }.freeze

      attr_reader :symbolic_name,
                  :vpc_id,
                  :subnet_ids,
                  :security_group_ids,
                  :deletion_policy,
                  :update_replace_policy,
                  :lifecycle_policies,
                  :throughput_mode,
                  :provisioned_throughput_in_mibps,
                  :encrypted,
                  :kms_key_id,
                  :backup,
                  :alarms,
                  :tags

      alias name symbolic_name
      alias subnets subnet_ids
      alias security_groups security_group_ids
      alias lifecycle_policy lifecycle_policies
      alias provisioned_throughput provisioned_throughput_in_mibps
      alias kms_key kms_key_id
      alias kms_key_arn kms_key_id
      alias backup_policy backup
      alias backup_plan backup
      alias efs_alarms alarms

      class << self
        def normalize_deletion_policy(policy, deletion_protection: nil)
          if policy.nil?
            return deletion_protection == false ? 'Delete' : 'Retain'
          end
          return 'Retain' if policy == true
          return 'Delete' if policy == false

          key = policy.to_s.strip.downcase
          normalized = DELETION_POLICY_MAP[key]
          return normalized if normalized

          raise ValidationError,
                "Invalid ManagedFileSystem deletion_policy '#{policy}'. " \
                'Valid values are: :retain, :delete, :snapshot, :retain_except_on_create'
        end

        def normalize_update_replace_policy(policy, deletion_protection: nil)
          if policy.nil?
            return deletion_protection == false ? 'Delete' : 'Retain'
          end
          return 'Retain' if policy == true
          return 'Delete' if policy == false

          key = policy.to_s.strip.downcase
          normalized = UPDATE_REPLACE_POLICY_MAP[key]
          return normalized if normalized

          raise ValidationError,
                "Invalid ManagedFileSystem update_replace_policy '#{policy}'. " \
                'Valid values are: :retain, :delete, :snapshot'
        end
      end

      def initialize(
        symbolic_name: :default,
        vpc_id: nil,
        subnet_ids: nil,
        subnets: nil,
        security_group_ids: nil,
        security_groups: nil,
        deletion_policy: nil,
        update_replace_policy: nil,
        deletion_protection: nil,
        lifecycle_policies: nil,
        lifecycle_policy: nil,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil,
        throughput_mode: nil,
        provisioned_throughput_in_mibps: nil,
        provisioned_throughput: nil,
        encrypted: nil,
        kms_key_id: nil,
        kms_key: nil,
        kms_key_arn: nil,
        backup: nil,
        backup_policy: nil,
        backup_plan: nil,
        backup_schedule: nil,
        backup_retention_days: nil,
        alarms: nil,
        efs_alarms: nil,
        burst_credit_balance: nil,
        burst_credit_balance_threshold: nil,
        burst_credit_threshold: nil,
        percent_io_limit: nil,
        percent_io_limit_threshold: nil,
        io_limit_threshold: nil,
        alarm_topic: nil,
        tags: nil
      )
        raw_subnets = subnet_ids.nil? ? subnets : subnet_ids
        raw_sgs = security_group_ids.nil? ? security_groups : security_group_ids

        normalized_vpc_id = normalize_vpc_id(vpc_id)
        normalized_subnets = normalize_subnet_ids(raw_subnets)
        normalized_sgs = normalize_security_group_ids(raw_sgs)

        if normalized_vpc_id.nil? && normalized_sgs.empty?
          raise ValidationError,
                'ManagedFileSystem requires vpc_id (for automatic security group generation) ' \
                'or explicit security_group_ids'
        end

        normalized_del_policy = self.class.normalize_deletion_policy(
          deletion_policy,
          deletion_protection: deletion_protection
        )
        normalized_upd_policy = self.class.normalize_update_replace_policy(
          update_replace_policy,
          deletion_protection: deletion_protection
        )

        normalized_lifecycle = ManagedAccessPoint.normalize_lifecycle_policies(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        normalized_tp_mode, normalized_prov_tp = ManagedAccessPoint.normalize_throughput_config(
          throughput_mode: throughput_mode,
          provisioned_throughput_in_mibps: provisioned_throughput_in_mibps,
          provisioned_throughput: provisioned_throughput
        )
        normalized_enc, normalized_kms = ManagedAccessPoint.normalize_encryption_config(
          encrypted: encrypted,
          kms_key_id: kms_key_id,
          kms_key: kms_key,
          kms_key_arn: kms_key_arn
        )
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        normalized_backup = ManagedAccessPoint.normalize_backup_config(
          raw_backup,
          schedule: backup_schedule,
          retention_days: backup_retention_days
        )
        raw_alarms = alarms.nil? ? efs_alarms : alarms
        normalized_alarms = ManagedAccessPoint.normalize_alarms_config(
          raw_alarms,
          burst_credit_balance: burst_credit_balance,
          burst_credit_balance_threshold: burst_credit_balance_threshold,
          burst_credit_threshold: burst_credit_threshold,
          percent_io_limit: percent_io_limit,
          percent_io_limit_threshold: percent_io_limit_threshold,
          io_limit_threshold: io_limit_threshold,
          topic: alarm_topic
        )

        @symbolic_name = (symbolic_name || :default).to_s.freeze
        @vpc_id = normalized_vpc_id
        @subnet_ids = normalized_subnets
        @security_group_ids = normalized_sgs
        @deletion_policy = normalized_del_policy.freeze
        @update_replace_policy = normalized_upd_policy.freeze
        @lifecycle_policies = normalized_lifecycle
        @throughput_mode = normalized_tp_mode
        @provisioned_throughput_in_mibps = normalized_prov_tp
        @encrypted = normalized_enc
        @kms_key_id = normalized_kms
        @backup = normalized_backup
        @alarms = normalized_alarms
        @tags = freeze_tags(tags)

        freeze
      end

      def deletion_protection?
        @deletion_policy == 'Retain' && @update_replace_policy == 'Retain'
      end

      def encrypted?
        @encrypted == true || !@kms_key_id.nil?
      end

      def kms_key?
        !@kms_key_id.nil?
      end
      alias customer_managed_kms_key? kms_key?

      def encryption_configuration?
        !@encrypted.nil? || !@kms_key_id.nil?
      end

      def lifecycle_policies?
        !@lifecycle_policies.nil? && !@lifecycle_policies.empty?
      end

      def throughput_configuration?
        !@throughput_mode.nil? || !@provisioned_throughput_in_mibps.nil?
      end

      def backup?
        !@backup.nil? && !@backup.empty?
      end

      def alarms?
        !@alarms.nil? && !@alarms.empty?
      end

      private

      def normalize_vpc_id(raw)
        return nil if raw.nil?
        return freeze_hash(raw) if raw.is_a?(Hash)
        return raw if !raw.is_a?(Symbol) && raw.respond_to?(:name)
        return raw if raw.is_a?(Symbol)

        str = raw.to_s.strip
        raise ValidationError, 'ManagedFileSystem vpc_id cannot be empty' if str.empty?

        unless VPC_ID_PATTERN.match?(str)
          raise ValidationError,
                "Invalid ManagedFileSystem vpc_id '#{str}'. Must match vpc-<hex> or be a parameter reference"
        end

        str.freeze
      end

      def normalize_subnet_ids(raw)
        list = Array(raw).flatten.compact
        if list.empty?
          raise ValidationError, 'ManagedFileSystem subnet_ids is required and must contain at least one subnet'
        end

        list.map { |sub| normalize_single_subnet_id(sub) }.freeze
      end

      def normalize_single_subnet_id(sub)
        return freeze_hash(sub) if sub.is_a?(Hash)
        return sub if !sub.is_a?(Symbol) && sub.respond_to?(:name)
        return sub if sub.is_a?(Symbol)

        str = sub.to_s.strip
        raise ValidationError, 'ManagedFileSystem subnet_id cannot be empty' if str.empty?

        unless SUBNET_ID_PATTERN.match?(str)
          raise ValidationError,
                "Invalid ManagedFileSystem subnet_id '#{str}'. Must match subnet-<hex> or be a parameter reference"
        end

        str.freeze
      end

      def normalize_security_group_ids(raw)
        return [].freeze if raw.nil?

        Array(raw).flatten.compact.map do |sg|
          if sg.is_a?(Hash)
            freeze_hash(sg)
          elsif (!sg.is_a?(Symbol) && sg.respond_to?(:name)) || sg.is_a?(Symbol)
            sg
          else
            str = sg.to_s.strip
            raise ValidationError, 'ManagedFileSystem security_group_id cannot be empty' if str.empty?

            str.freeze
          end
        end.freeze
      end

      def freeze_tags(tags)
        return {}.freeze if tags.nil? || tags.empty?

        tags.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = v.to_s.freeze
        end.freeze
      end

      def freeze_hash(hash)
        return {}.freeze if hash.nil?

        hash.each_with_object({}) do |(k, v), memo|
          memo[k.to_s.freeze] = v.is_a?(Hash) ? freeze_hash(v) : v.to_s.freeze
        end.freeze
      end
    end
  end
end
