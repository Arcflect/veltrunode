# frozen_string_literal: true

module Veltrunode
  module Model
    # 自動管理・生成される EFS アクセスポイントのモデル
    class ManagedAccessPoint
      FILE_SYSTEM_ID_PATTERN = /\Afs-[a-f0-9]+\z/i
      VALID_TRANSITION_VALUES = %w[
        AFTER_1_DAY
        AFTER_7_DAYS
        AFTER_14_DAYS
        AFTER_30_DAYS
        AFTER_60_DAYS
        AFTER_90_DAYS
        AFTER_180_DAYS
        AFTER_270_DAYS
        AFTER_365_DAYS
      ].freeze
      TRANSITION_DAYS_MAP = {
        'AFTER_1_DAY' => 1,
        'AFTER_7_DAYS' => 7,
        'AFTER_14_DAYS' => 14,
        'AFTER_30_DAYS' => 30,
        'AFTER_60_DAYS' => 60,
        'AFTER_90_DAYS' => 90,
        'AFTER_180_DAYS' => 180,
        'AFTER_270_DAYS' => 270,
        'AFTER_365_DAYS' => 365
      }.freeze
      VALID_PRIMARY_STORAGE_CLASS_VALUES = %w[AFTER_1_ACCESS].freeze
      VALID_THROUGHPUT_MODES = %w[bursting provisioned elastic].freeze
      DEFAULT_BACKUP_SCHEDULE = 'cron(0 12 * * ? *)'
      DEFAULT_BACKUP_RETENTION_DAYS = 30
      BACKUP_SCHEDULE_PATTERN = /\A(cron|rate)\(.+\)\z/
      DEFAULT_BURST_CREDIT_THRESHOLD = 1_073_741_824 # 1 GiB
      DEFAULT_PERCENT_IO_LIMIT_THRESHOLD = 80
      DEFAULT_ALARM_PERIOD = 300
      DEFAULT_ALARM_EVALUATION_PERIODS = 1
      BYTE_UNIT_MULTIPLIERS = {
        'B' => 1,
        'KB' => 1_000,
        'KIB' => 1_024,
        'MB' => 1_000_000,
        'MIB' => 1_048_576,
        'GB' => 1_000_000_000,
        'GIB' => 1_073_741_824,
        'TB' => 1_000_000_000_000,
        'TIB' => 1_099_511_627_776
      }.freeze

      attr_reader :file_system_id,
                  :root_directory_path,
                  :posix_user,
                  :creation_info,
                  :lifecycle_policies,
                  :throughput_mode,
                  :provisioned_throughput_in_mibps,
                  :backup,
                  :alarms,
                  :tags

      alias lifecycle_policy lifecycle_policies
      alias provisioned_throughput provisioned_throughput_in_mibps
      alias backup_policy backup
      alias backup_plan backup
      alias efs_alarms alarms

      class << self
        def normalize_alarms_config(
          alarms = nil,
          burst_credit_balance: nil,
          burst_credit_balance_threshold: nil,
          burst_credit_threshold: nil,
          percent_io_limit: nil,
          percent_io_limit_threshold: nil,
          io_limit_threshold: nil,
          topic: nil,
          alarm_actions: nil
        )
          has_kwargs = !burst_credit_balance.nil? || !burst_credit_balance_threshold.nil? ||
                       !burst_credit_threshold.nil? || !percent_io_limit.nil? ||
                       !percent_io_limit_threshold.nil? || !io_limit_threshold.nil? ||
                       !topic.nil? || !alarm_actions.nil?
          return nil if alarms.nil? && !has_kwargs
          return nil if alarms == false

          if !alarms.nil? && alarms != true && !alarms.is_a?(Hash)
            raise ValidationError,
                  "Invalid EFS alarms configuration '#{alarms}'. Must be true, false, or a Hash"
          end

          raw = alarms.is_a?(Hash) ? alarms : {}
          return nil if raw[:enabled] == false || raw['enabled'] == false

          common_topic = topic || raw[:topic] || raw['topic'] || raw[:alarm_topic] || raw['alarm_topic']
          raw_actions = alarm_actions || raw[:alarm_actions] || raw['alarm_actions']
          common_actions = if raw_actions
                             raw_actions.is_a?(Array) ? raw_actions : [raw_actions]
                           elsif common_topic
                             common_topic.is_a?(Array) ? common_topic : [common_topic]
                           else
                             []
                           end
          common_ok_actions = Array(raw[:ok_actions] || raw['ok_actions']).compact
          common_period = raw[:period] || raw['period'] || DEFAULT_ALARM_PERIOD
          common_eval_periods = raw[:evaluation_periods] || raw['evaluation_periods'] ||
                                DEFAULT_ALARM_EVALUATION_PERIODS
          common_treat_missing = (raw[:treat_missing_data] || raw['treat_missing_data'] || 'notBreaching').to_s

          raw_bc = extract_alarm_metric_raw(
            raw,
            [burst_credit_balance, burst_credit_balance_threshold, burst_credit_threshold],
            %i[burst_credit_balance BurstCreditBalance burst_credit_balance_threshold burst_credit_threshold]
          )
          raw_io = extract_alarm_metric_raw(
            raw,
            [percent_io_limit, percent_io_limit_threshold, io_limit_threshold],
            %i[percent_io_limit PercentIOLimit percent_io_limit_threshold io_limit_threshold]
          )

          result = {}
          unless raw_bc == false
            result['burst_credit_balance'] = build_burst_credit_alarm_entry(
              raw_bc,
              common_period: common_period,
              common_eval_periods: common_eval_periods,
              common_treat_missing: common_treat_missing,
              common_actions: common_actions,
              common_ok_actions: common_ok_actions
            )
          end
          unless raw_io == false
            result['percent_io_limit'] = build_percent_io_limit_alarm_entry(
              raw_io,
              common_period: common_period,
              common_eval_periods: common_eval_periods,
              common_treat_missing: common_treat_missing,
              common_actions: common_actions,
              common_ok_actions: common_ok_actions
            )
          end

          return nil if result.empty?

          result['topic'] = common_topic if common_topic
          result.freeze
        end

        def normalize_backup_config(
          backup = nil,
          schedule: nil,
          retention_days: nil,
          cold_storage_after_days: nil,
          vault_name: nil,
          plan_name: nil,
          rule_name: nil
        )
          has_kwargs = !schedule.nil? || !retention_days.nil? || !cold_storage_after_days.nil? ||
                       !vault_name.nil? || !plan_name.nil? || !rule_name.nil?
          return nil if backup.nil? && !has_kwargs
          return nil if backup == false

          if !backup.nil? && backup != true && !backup.is_a?(Hash)
            raise ValidationError,
                  "Invalid EFS backup configuration '#{backup}'. Must be true, false, or a Hash"
          end

          raw = backup.is_a?(Hash) ? backup : {}
          return nil if raw[:enabled] == false || raw['enabled'] == false

          raw_schedule = schedule ||
                         raw[:schedule] || raw['schedule'] ||
                         raw[:schedule_expression] || raw['schedule_expression'] ||
                         raw[:ScheduleExpression] || raw['ScheduleExpression'] ||
                         DEFAULT_BACKUP_SCHEDULE
          raw_retention = retention_days ||
                          raw[:retention_days] || raw['retention_days'] ||
                          raw[:delete_after_days] || raw['delete_after_days'] ||
                          raw[:DeleteAfterDays] || raw['DeleteAfterDays'] ||
                          raw[:retention] || raw['retention'] ||
                          DEFAULT_BACKUP_RETENTION_DAYS
          raw_cold = cold_storage_after_days ||
                     raw[:cold_storage_after_days] || raw['cold_storage_after_days'] ||
                     raw[:move_to_cold_storage_after_days] || raw['move_to_cold_storage_after_days'] ||
                     raw[:MoveToColdStorageAfterDays] || raw['MoveToColdStorageAfterDays']
          raw_vault = vault_name ||
                      raw[:vault_name] || raw['vault_name'] ||
                      raw[:backup_vault_name] || raw['backup_vault_name']
          raw_plan = plan_name ||
                     raw[:plan_name] || raw['plan_name'] ||
                     raw[:backup_plan_name] || raw['backup_plan_name']
          raw_rule = rule_name || raw[:rule_name] || raw['rule_name']

          norm_schedule = normalize_backup_schedule!(raw_schedule)
          norm_retention = normalize_backup_positive_integer!(raw_retention, :retention_days)
          norm_cold = raw_cold.nil? ? nil : normalize_backup_positive_integer!(raw_cold, :cold_storage_after_days)

          if norm_cold && norm_cold >= norm_retention
            raise ValidationError,
                  "EFS backup cold_storage_after_days (#{norm_cold}) " \
                  "must be less than retention_days (#{norm_retention})"
          end

          result = {
            'schedule' => norm_schedule,
            'retention_days' => norm_retention
          }
          result['cold_storage_after_days'] = norm_cold if norm_cold
          result['vault_name'] = raw_vault.to_s.strip.freeze if raw_vault && !raw_vault.to_s.strip.empty?
          result['plan_name'] = raw_plan.to_s.strip.freeze if raw_plan && !raw_plan.to_s.strip.empty?
          result['rule_name'] = raw_rule.to_s.strip.freeze if raw_rule && !raw_rule.to_s.strip.empty?
          result.freeze
        end

        def normalize_throughput_config(
          throughput_mode: nil,
          provisioned_throughput_in_mibps: nil,
          provisioned_throughput: nil
        )
          raw_pt = provisioned_throughput_in_mibps.nil? ? provisioned_throughput : provisioned_throughput_in_mibps
          normalized_pt = raw_pt.nil? ? nil : normalize_provisioned_throughput!(raw_pt)
          normalized_mode = throughput_mode.nil? ? nil : normalize_throughput_mode!(throughput_mode)
          normalized_mode ||= 'provisioned' if normalized_pt

          if normalized_mode == 'provisioned' && normalized_pt.nil?
            raise ValidationError,
                  "EFS throughput_mode 'provisioned' requires provisioned_throughput_in_mibps"
          end

          if normalized_mode && normalized_mode != 'provisioned' && !normalized_pt.nil?
            raise ValidationError,
                  "EFS provisioned_throughput_in_mibps can only be specified when throughput_mode is 'provisioned' " \
                  "(got '#{normalized_mode}')"
          end

          [normalized_mode, normalized_pt]
        end

        def normalize_lifecycle_policies(
          policies = nil,
          transition_to_ia: nil,
          transition_to_archive: nil,
          transition_to_primary_storage_class: nil
        )
          raw = extract_raw_lifecycle_hash(policies)
          ia_raw = transition_to_ia || raw[:transition_to_ia]
          archive_raw = transition_to_archive || raw[:transition_to_archive]
          primary_raw = transition_to_primary_storage_class || raw[:transition_to_primary_storage_class]

          return nil if ia_raw.nil? && archive_raw.nil? && primary_raw.nil?

          result = {}
          result['transition_to_ia'] = normalize_transition_value!(ia_raw, :transition_to_ia) if ia_raw
          if archive_raw
            result['transition_to_archive'] =
              normalize_transition_value!(archive_raw, :transition_to_archive)
          end
          if primary_raw
            result['transition_to_primary_storage_class'] = normalize_primary_storage_class_value!(primary_raw)
          end

          if result['transition_to_ia'] && result['transition_to_archive']
            ia_days = TRANSITION_DAYS_MAP[result['transition_to_ia']]
            arch_days = TRANSITION_DAYS_MAP[result['transition_to_archive']]
            if ia_days && arch_days && arch_days < ia_days
              raise ValidationError,
                    "EFS lifecycle transition_to_archive (#{result['transition_to_archive']}) " \
                    "must not be shorter than transition_to_ia (#{result['transition_to_ia']})"
            end
          end

          result.freeze
        end

        def to_cfn_lifecycle_policies(policies)
          normalized = policies.is_a?(Hash) && policies.frozen? ? policies : normalize_lifecycle_policies(policies)
          return [] if normalized.nil? || normalized.empty?

          list = []
          ia = normalized['transition_to_ia'] || normalized[:transition_to_ia]
          archive = normalized['transition_to_archive'] || normalized[:transition_to_archive]
          primary = normalized['transition_to_primary_storage_class'] ||
                    normalized[:transition_to_primary_storage_class]

          list << { 'TransitionToIA' => ia.to_s } if ia
          list << { 'TransitionToArchive' => archive.to_s } if archive
          list << { 'TransitionToPrimaryStorageClass' => primary.to_s } if primary
          list
        end

        private

        def extract_raw_lifecycle_hash(policies)
          result = {}
          return result if policies.nil?

          items = policies.is_a?(Array) ? policies : [policies]
          items.each do |item|
            next unless item.is_a?(Hash)

            ia = item[:transition_to_ia] || item['transition_to_ia'] ||
                 item[:TransitionToIA] || item['TransitionToIA']
            arch = item[:transition_to_archive] || item['transition_to_archive'] ||
                   item[:TransitionToArchive] || item['TransitionToArchive']
            prim = item[:transition_to_primary_storage_class] || item['transition_to_primary_storage_class'] ||
                   item[:TransitionToPrimaryStorageClass] || item['TransitionToPrimaryStorageClass']

            result[:transition_to_ia] = ia if ia
            result[:transition_to_archive] = arch if arch
            result[:transition_to_primary_storage_class] = prim if prim
          end
          result
        end

        def normalize_transition_value!(val, field_name)
          str = val.to_s.strip.upcase
          candidate = case str
                      when '1', '1_DAY'
                        'AFTER_1_DAY'
                      when /\A\d+\z/
                        "AFTER_#{str}_DAYS"
                      when /\A\d+_DAYS?\z/
                        "AFTER_#{str}"
                      else
                        str
                      end

          return candidate.freeze if VALID_TRANSITION_VALUES.include?(candidate)

          raise ValidationError,
                "Invalid EFS lifecycle #{field_name} '#{val}'. " \
                "Must be one of: #{VALID_TRANSITION_VALUES.join(', ')}"
        end

        def normalize_primary_storage_class_value!(val)
          candidate = val.to_s.strip.upcase
          return candidate.freeze if VALID_PRIMARY_STORAGE_CLASS_VALUES.include?(candidate)

          raise ValidationError,
                "Invalid EFS lifecycle transition_to_primary_storage_class '#{val}'. " \
                "Must be one of: #{VALID_PRIMARY_STORAGE_CLASS_VALUES.join(', ')}"
        end

        def normalize_throughput_mode!(val)
          candidate = val.to_s.strip.downcase
          return candidate.freeze if VALID_THROUGHPUT_MODES.include?(candidate)

          raise ValidationError,
                "Invalid EFS throughput_mode '#{val}'. " \
                "Must be one of: #{VALID_THROUGHPUT_MODES.join(', ')}"
        end

        def normalize_provisioned_throughput!(val)
          num = if val.is_a?(Integer) || val.is_a?(Float)
                  val
                elsif val.is_a?(Numeric)
                  val.to_f
                elsif val.is_a?(String) && val.strip.match?(/\A-?\d+(\.\d+)?\z/)
                  str = val.strip
                  str.include?('.') ? Float(str) : Integer(str, 10)
                else
                  raise ValidationError,
                        "Invalid EFS provisioned_throughput_in_mibps '#{val}'. Must be a positive number"
                end

          return num if num.positive?

          raise ValidationError,
                "Invalid EFS provisioned_throughput_in_mibps '#{val}'. Must be a positive number (> 0)"
        end

        def normalize_backup_schedule!(val)
          str = val.to_s.strip
          if str.empty? || !BACKUP_SCHEDULE_PATTERN.match?(str)
            raise ValidationError,
                  "Invalid EFS backup schedule '#{val}'. Must be a valid cron(...) or rate(...) expression"
          end

          str.freeze
        end

        def normalize_backup_positive_integer!(val, field_name)
          num = if val.is_a?(Integer)
                  val
                elsif val.is_a?(String) && val.strip.match?(/\A-?\d+\z/)
                  Integer(val.strip, 10)
                else
                  raise ValidationError,
                        "Invalid EFS backup #{field_name} '#{val}'. Must be a positive integer (> 0)"
                end

          return num if num.positive?

          raise ValidationError,
                "Invalid EFS backup #{field_name} '#{val}'. Must be a positive integer (> 0)"
        end

        def extract_alarm_metric_raw(raw_hash, explicit_values, keys)
          explicit_values.each do |val|
            return val unless val.nil?
          end

          keys.each do |k|
            return raw_hash[k] if raw_hash.key?(k)
            return raw_hash[k.to_s] if raw_hash.key?(k.to_s)
          end

          nil
        end

        def build_burst_credit_alarm_entry(
          raw_bc,
          common_period:,
          common_eval_periods:,
          common_treat_missing:,
          common_actions:,
          common_ok_actions:
        )
          opts = raw_bc.is_a?(Hash) ? raw_bc : {}
          raw_threshold = if raw_bc.is_a?(Hash)
                            opts[:threshold] || opts['threshold'] || DEFAULT_BURST_CREDIT_THRESHOLD
                          elsif raw_bc.nil? || raw_bc == true
                            DEFAULT_BURST_CREDIT_THRESHOLD
                          else
                            raw_bc
                          end
          threshold = normalize_burst_credit_threshold!(raw_threshold)
          comp_op = (opts[:comparison_operator] || opts['comparison_operator'] || 'LessThanOrEqualToThreshold').to_s
          stat = (opts[:statistic] || opts['statistic'] || 'Minimum').to_s
          period = normalize_alarm_period!(opts[:period] || opts['period'] || common_period)
          eval_periods = normalize_alarm_evaluation_periods!(
            opts[:evaluation_periods] || opts['evaluation_periods'] || common_eval_periods
          )
          treat_missing = (opts[:treat_missing_data] || opts['treat_missing_data'] || common_treat_missing).to_s
          actions = extract_alarm_actions(opts, common_actions)
          ok_actions = Array(opts[:ok_actions] || opts['ok_actions'] || common_ok_actions).compact

          {
            'metric_name' => 'BurstCreditBalance',
            'threshold' => threshold,
            'comparison_operator' => comp_op.freeze,
            'statistic' => stat.freeze,
            'period' => period,
            'evaluation_periods' => eval_periods,
            'treat_missing_data' => treat_missing.freeze,
            'alarm_actions' => actions.freeze,
            'ok_actions' => ok_actions.freeze
          }.freeze
        end

        def build_percent_io_limit_alarm_entry(
          raw_io,
          common_period:,
          common_eval_periods:,
          common_treat_missing:,
          common_actions:,
          common_ok_actions:
        )
          opts = raw_io.is_a?(Hash) ? raw_io : {}
          raw_threshold = if raw_io.is_a?(Hash)
                            opts[:threshold] || opts['threshold'] || DEFAULT_PERCENT_IO_LIMIT_THRESHOLD
                          elsif raw_io.nil? || raw_io == true
                            DEFAULT_PERCENT_IO_LIMIT_THRESHOLD
                          else
                            raw_io
                          end
          threshold = normalize_percent_io_limit_threshold!(raw_threshold)
          comp_op = (opts[:comparison_operator] || opts['comparison_operator'] || 'GreaterThanOrEqualToThreshold').to_s
          stat = (opts[:statistic] || opts['statistic'] || 'Average').to_s
          period = normalize_alarm_period!(opts[:period] || opts['period'] || common_period)
          eval_periods = normalize_alarm_evaluation_periods!(
            opts[:evaluation_periods] || opts['evaluation_periods'] || common_eval_periods
          )
          treat_missing = (opts[:treat_missing_data] || opts['treat_missing_data'] || common_treat_missing).to_s
          actions = extract_alarm_actions(opts, common_actions)
          ok_actions = Array(opts[:ok_actions] || opts['ok_actions'] || common_ok_actions).compact

          {
            'metric_name' => 'PercentIOLimit',
            'threshold' => threshold,
            'comparison_operator' => comp_op.freeze,
            'statistic' => stat.freeze,
            'period' => period,
            'evaluation_periods' => eval_periods,
            'treat_missing_data' => treat_missing.freeze,
            'alarm_actions' => actions.freeze,
            'ok_actions' => ok_actions.freeze
          }.freeze
        end

        def extract_alarm_actions(opts, fallback_actions)
          raw = opts[:alarm_actions] || opts['alarm_actions'] || opts[:topic] || opts['topic']
          return fallback_actions if raw.nil?

          raw.is_a?(Array) ? raw : [raw]
        end

        def normalize_burst_credit_threshold!(val)
          num = parse_byte_or_numeric_threshold(val, 'burst_credit_balance')
          return num if num.positive?

          raise ValidationError,
                "Invalid EFS alarm burst_credit_balance threshold '#{val}'. Must be a positive number (> 0)"
        end

        def parse_byte_or_numeric_threshold(val, field_name)
          case val
          when Integer, Float
            val
          when Numeric
            val.to_f
          when String
            str = val.strip
            if (m = str.match(/\A(-?\d+(?:\.\d+)?)\s*([a-zA-Z]+)?\z/))
              base = m[1].include?('.') ? Float(m[1]) : Integer(m[1], 10)
              unit = m[2]&.upcase
              return base if unit.nil? || unit.empty?

              mult = BYTE_UNIT_MULTIPLIERS[unit]
              raise ValidationError, "Invalid byte unit '#{m[2]}' in EFS alarm #{field_name} threshold" unless mult

              res = base * mult
              res.to_i == res ? res.to_i : res
            else
              raise ValidationError,
                    "Invalid EFS alarm #{field_name} threshold '#{val}'. Must be a positive number"
            end
          else
            raise ValidationError,
                  "Invalid EFS alarm #{field_name} threshold '#{val}'. Must be a positive number"
          end
        end

        def normalize_percent_io_limit_threshold!(val)
          num = if val.is_a?(Integer) || val.is_a?(Float)
                  val
                elsif val.is_a?(Numeric)
                  val.to_f
                elsif val.is_a?(String) && val.strip.match?(/\A-?\d+(\.\d+)?%?\z/)
                  cleaned = val.strip.delete_suffix('%')
                  cleaned.include?('.') ? Float(cleaned) : Integer(cleaned, 10)
                else
                  raise ValidationError,
                        "Invalid EFS alarm percent_io_limit threshold '#{val}'. Must be between 1 and 100"
                end

          return num if num.positive? && num <= 100

          raise ValidationError,
                "Invalid EFS alarm percent_io_limit threshold '#{val}'. Must be between 1 and 100"
        end

        def normalize_alarm_period!(val)
          period = Integer(val)
          return period if period >= 10 && (period % 10).zero?

          raise ValidationError,
                "Invalid EFS alarm period '#{val}'. Must be a multiple of 10 seconds (>= 10)"
        rescue ArgumentError, TypeError
          raise ValidationError,
                "Invalid EFS alarm period '#{val}'. Must be a multiple of 10 seconds (>= 10)"
        end

        def normalize_alarm_evaluation_periods!(val)
          eval_periods = Integer(val)
          return eval_periods if eval_periods >= 1

          raise ValidationError,
                "Invalid EFS alarm evaluation_periods '#{val}'. Must be at least 1"
        rescue ArgumentError, TypeError
          raise ValidationError,
                "Invalid EFS alarm evaluation_periods '#{val}'. Must be at least 1"
        end
      end

      def initialize(
        file_system_id: :__unset__,
        root_directory_path: nil,
        posix_user: nil,
        creation_info: nil,
        lifecycle_policies: nil,
        lifecycle_policy: nil,
        transition_to_ia: nil,
        transition_to_archive: nil,
        transition_to_primary_storage_class: nil,
        throughput_mode: nil,
        provisioned_throughput_in_mibps: nil,
        provisioned_throughput: nil,
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
        resolved_lifecycle = self.class.normalize_lifecycle_policies(
          lifecycle_policies || lifecycle_policy,
          transition_to_ia: transition_to_ia,
          transition_to_archive: transition_to_archive,
          transition_to_primary_storage_class: transition_to_primary_storage_class
        )
        resolved_tp_mode, resolved_prov_tp = self.class.normalize_throughput_config(
          throughput_mode: throughput_mode,
          provisioned_throughput_in_mibps: provisioned_throughput_in_mibps,
          provisioned_throughput: provisioned_throughput
        )
        raw_backup = if !backup.nil?
                       backup
                     elsif !backup_policy.nil?
                       backup_policy
                     else
                       backup_plan
                     end
        resolved_backup = self.class.normalize_backup_config(
          raw_backup,
          schedule: backup_schedule,
          retention_days: backup_retention_days
        )
        raw_alarms = alarms.nil? ? efs_alarms : alarms
        resolved_alarms = self.class.normalize_alarms_config(
          raw_alarms,
          burst_credit_balance: burst_credit_balance,
          burst_credit_balance_threshold: burst_credit_balance_threshold,
          burst_credit_threshold: burst_credit_threshold,
          percent_io_limit: percent_io_limit,
          percent_io_limit_threshold: percent_io_limit_threshold,
          io_limit_threshold: io_limit_threshold,
          topic: alarm_topic
        )
        has_fs_config = !resolved_lifecycle.nil? || !resolved_tp_mode.nil? ||
                        !resolved_prov_tp.nil? || !resolved_backup.nil? || !resolved_alarms.nil?
        allow_nil_fs_id = (file_system_id == :__unset__ || file_system_id.nil?) && has_fs_config
        resolved_fs_id = file_system_id == :__unset__ ? nil : file_system_id

        resolved_root_path = root_directory_path ? root_directory_path.to_s.strip : '/'
        validate!(
          file_system_id: resolved_fs_id,
          allow_nil_fs_id: allow_nil_fs_id,
          root_directory_path: resolved_root_path,
          posix_user: posix_user,
          creation_info: creation_info
        )

        @file_system_id = if resolved_fs_id.is_a?(Hash)
                            resolved_fs_id.dup.freeze
                          elsif resolved_fs_id
                            resolved_fs_id.to_s.strip.freeze
                          end
        @root_directory_path = resolved_root_path.freeze
        @posix_user = normalize_posix_user(posix_user)
        @creation_info = normalize_creation_info(creation_info)
        @lifecycle_policies = resolved_lifecycle
        @throughput_mode = resolved_tp_mode
        @provisioned_throughput_in_mibps = resolved_prov_tp
        @backup = resolved_backup
        @alarms = resolved_alarms
        @tags = tags ? freeze_hash(tags) : {}.freeze

        freeze
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
      alias efs_alarms? alarms?

      def burst_credit_balance_threshold
        @alarms&.dig('burst_credit_balance', 'threshold')
      end
      alias burst_credit_threshold burst_credit_balance_threshold

      def percent_io_limit_threshold
        @alarms&.dig('percent_io_limit', 'threshold')
      end
      alias io_limit_threshold percent_io_limit_threshold

      def alarm_topic
        @alarms&.fetch('topic', nil)
      end

      def backup_schedule
        @backup&.fetch('schedule', nil)
      end

      def backup_retention_days
        @backup&.fetch('retention_days', nil)
      end

      def backup_cold_storage_after_days
        @backup&.fetch('cold_storage_after_days', nil)
      end

      def file_system_configuration?
        lifecycle_policies? || throughput_configuration? ||
          ((backup? || alarms?) && @file_system_id.nil?)
      end

      def transition_to_ia
        @lifecycle_policies&.fetch('transition_to_ia', nil)
      end

      def transition_to_archive
        @lifecycle_policies&.fetch('transition_to_archive', nil)
      end

      def transition_to_primary_storage_class
        @lifecycle_policies&.fetch('transition_to_primary_storage_class', nil)
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

      def validate!(file_system_id:, root_directory_path:, posix_user:, creation_info:, allow_nil_fs_id: false)
        validate_file_system_id!(file_system_id) unless allow_nil_fs_id && file_system_id.nil?
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
