# frozen_string_literal: true

require_relative '../../diagnostics/diagnostic'

module Veltrunode
  module AWS
    module Inspectors
      # EFS ストレージ消費量（Standard / IA / Archive）およびリージョン内クォータを検査するインスペクター
      class EfsQuotaInspector
        DEFAULT_MAX_FILE_SYSTEMS = 1000
        DEFAULT_MAX_MOUNT_TARGETS = 1000
        DEFAULT_MAX_MOUNT_TARGETS_PER_FS = 32
        DEFAULT_MAX_FILE_SYSTEM_SIZE_BYTES = 281_474_976_710_656 # 256 TiB
        QUOTA_WARNING_THRESHOLD_PERCENT = 80.0

        # 個別ファイルシステムのサイズ・マウントターゲット使用状況を表す値オブジェクト
        class FileSystemUsage
          attr_reader :file_system_id, :name, :mount_name, :life_cycle_state, :throughput_mode,
                      :total_bytes, :standard_bytes, :ia_bytes, :archive_bytes,
                      :size_limit_bytes, :mount_targets_count, :mount_targets_limit

          alias size_in_bytes total_bytes
          alias value_in_standard standard_bytes
          alias value_in_ia ia_bytes
          alias value_in_archive archive_bytes
          alias number_of_mount_targets mount_targets_count

          def initialize(
            file_system_id:,
            name: nil,
            mount_name: nil,
            life_cycle_state: 'available',
            throughput_mode: 'bursting',
            total_bytes: 0,
            standard_bytes: 0,
            ia_bytes: 0,
            archive_bytes: 0,
            size_limit_bytes: DEFAULT_MAX_FILE_SYSTEM_SIZE_BYTES,
            mount_targets_count: 0,
            mount_targets_limit: DEFAULT_MAX_MOUNT_TARGETS_PER_FS
          )
            @file_system_id = file_system_id.to_s.freeze
            @name = name&.to_s&.freeze
            @mount_name = mount_name&.to_s&.freeze
            @life_cycle_state = (life_cycle_state || 'available').to_s.freeze
            @throughput_mode = (throughput_mode || 'bursting').to_s.freeze
            @total_bytes = total_bytes.to_i
            @standard_bytes = standard_bytes.to_i
            @ia_bytes = ia_bytes.to_i
            @archive_bytes = archive_bytes.to_i
            @size_limit_bytes = size_limit_bytes.to_i
            @mount_targets_count = mount_targets_count.to_i
            @mount_targets_limit = mount_targets_limit.to_i
            freeze
          end

          def display_name
            @mount_name || @name || '-'
          end

          def to_h
            {
              'file_system_id' => @file_system_id,
              'name' => @name,
              'mount_name' => @mount_name,
              'life_cycle_state' => @life_cycle_state,
              'throughput_mode' => @throughput_mode,
              'size_in_bytes' => {
                'total' => @total_bytes,
                'standard' => @standard_bytes,
                'ia' => @ia_bytes,
                'archive' => @archive_bytes,
                'limit' => @size_limit_bytes
              },
              'total_bytes' => @total_bytes,
              'standard_bytes' => @standard_bytes,
              'ia_bytes' => @ia_bytes,
              'archive_bytes' => @archive_bytes,
              'size_limit_bytes' => @size_limit_bytes,
              'mount_targets' => {
                'used' => @mount_targets_count,
                'limit' => @mount_targets_limit
              },
              'number_of_mount_targets' => @mount_targets_count
            }
          end
        end

        # クォータおよびファイルシステムサイズ一覧のレポートを表す値オブジェクト
        class Report
          attr_reader :region, :file_systems, :quotas, :diagnostics

          def initialize(region:, file_systems: [], quotas: {}, diagnostics: [])
            @region = region.to_s.freeze
            @file_systems = file_systems.dup.freeze
            @quotas = quotas.dup.freeze
            @diagnostics = diagnostics.dup.freeze
            freeze
          end

          def success?
            @diagnostics.none? { |d| d.severity == :error }
          end

          def warnings?
            @diagnostics.any? { |d| d.severity == :warning }
          end
          alias has_warnings? warnings?

          def to_h
            {
              'region' => @region,
              'file_systems' => @file_systems.map(&:to_h),
              'quotas' => @quotas
            }
          end
        end

        class << self
          def inspect(application = nil, target_name: nil, **)
            new(application, target_name: target_name, **).inspect
          end

          def format_size(bytes)
            b = bytes.to_i
            return '0 B' if b <= 0

            if b >= 1_099_511_627_776
              format('%.2f TiB', b / 1_099_511_627_776.0)
            elsif b >= 1_073_741_824
              format('%.2f GiB', b / 1_073_741_824.0)
            elsif b >= 1_048_576
              format('%.2f MiB', b / 1_048_576.0)
            elsif b >= 1_024
              format('%.2f KiB', b / 1_024.0)
            else
              "#{b} B"
            end
          end
        end

        attr_reader :application, :target_name, :efs_client, :configured_region,
                    :file_systems_limit, :mount_targets_limit, :max_mount_targets_per_fs

        def initialize(
          application = nil,
          target_name: nil,
          efs_client: nil,
          aws_region: nil,
          file_systems_limit: DEFAULT_MAX_FILE_SYSTEMS,
          mount_targets_limit: DEFAULT_MAX_MOUNT_TARGETS,
          max_mount_targets_per_fs: DEFAULT_MAX_MOUNT_TARGETS_PER_FS
        )
          @application = application
          @target_name = target_name&.to_s&.strip
          @efs_client = efs_client
          @configured_region = aws_region
          @file_systems_limit = (file_systems_limit || DEFAULT_MAX_FILE_SYSTEMS).to_i
          @mount_targets_limit = (mount_targets_limit || DEFAULT_MAX_MOUNT_TARGETS).to_i
          @max_mount_targets_per_fs = (max_mount_targets_per_fs || DEFAULT_MAX_MOUNT_TARGETS_PER_FS).to_i
        end

        def inspect
          client = resolve_efs_client
          unless client
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-AWS-AUTH-001',
              severity: :error,
              summary: 'AWS SDK (aws-sdk-efs) is not available or valid AWS credentials could not be loaded for EFS.',
              suggested_action: 'Install aws-sdk-efs or configure valid AWS credentials.'
            )
            return Report.new(region: region, diagnostics: [diag])
          end

          diagnostics = []
          mount_fs_map = resolve_application_mount_map(client)
          raw_file_systems = fetch_all_file_systems(client)

          all_usages = raw_file_systems.map do |fs|
            build_file_system_usage(fs, client, mount_fs_map)
          end

          filtered_usages = filter_by_target(all_usages, mount_fs_map, diagnostics)
          quotas = build_quotas_summary(all_usages, diagnostics)

          Report.new(
            region: region,
            file_systems: filtered_usages,
            quotas: quotas,
            diagnostics: diagnostics
          )
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-FS-STATE',
            severity: :error,
            summary: "Failed to query EFS storage and quota information: #{e.message}",
            suggested_action: 'Verify IAM permissions for elasticfilesystem:DescribeFileSystems and AWS credentials.',
            evidence: { 'region' => region, 'error' => e.message }
          )
          Report.new(region: region, diagnostics: [diag])
        end

        private

        def region
          return configured_region.to_s.strip if configured_region && !configured_region.to_s.strip.empty?
          return application.region.to_s if application.respond_to?(:region) && application.region

          ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || 'ap-northeast-1'
        end

        def resolve_application_mount_map(client)
          return {} unless application.respond_to?(:mounts) && application.mounts

          map = {}
          Array(application.mounts).each do |mount|
            sym_name = mount.symbolic_name.to_s
            fs_id = extract_mount_file_system_id(mount, client)
            map[fs_id] = sym_name if fs_id
          end
          map
        end

        def extract_mount_file_system_id(mount, client)
          if mount.respond_to?(:managed_access_point) && mount.managed_access_point&.file_system_id
            return mount.managed_access_point.file_system_id.to_s
          end

          src = mount.respond_to?(:access_point_source) ? mount.access_point_source.to_s : ''
          if (m = src.match(%r{access-point/(fsap-[a-f0-9]+)\z})) && client.respond_to?(:describe_access_points)
            resp = client.describe_access_points(access_point_id: m[1])
            ap = resp.respond_to?(:access_points) ? resp.access_points&.first : nil
            return ap.file_system_id.to_s if ap.respond_to?(:file_system_id) && ap.file_system_id
          end

          nil
        rescue StandardError
          nil
        end

        def fetch_all_file_systems(client)
          if target_name&.start_with?('fs-')
            begin
              resp = client.describe_file_systems(file_system_id: target_name)
              return Array(resp.respond_to?(:file_systems) ? resp.file_systems : [])
            rescue StandardError
              # Fall back to listing all file systems
            end
          end

          resp = client.describe_file_systems
          Array(resp.respond_to?(:file_systems) ? resp.file_systems : [])
        end

        def build_file_system_usage(fs, client, mount_fs_map)
          fs_id = extract_field(fs, :file_system_id).to_s
          fs_name = extract_field(fs, :name)
          state = extract_field(fs, :life_cycle_state) || 'available'
          tp_mode = extract_field(fs, :throughput_mode) || 'bursting'
          mt_count = extract_mount_targets_count(fs, fs_id, client)
          total_b, std_b, ia_b, arch_b = extract_size_breakdown(fs)

          FileSystemUsage.new(
            file_system_id: fs_id,
            name: fs_name,
            mount_name: mount_fs_map[fs_id],
            life_cycle_state: state,
            throughput_mode: tp_mode,
            total_bytes: total_b,
            standard_bytes: std_b,
            ia_bytes: ia_b,
            archive_bytes: arch_b,
            size_limit_bytes: DEFAULT_MAX_FILE_SYSTEM_SIZE_BYTES,
            mount_targets_count: mt_count,
            mount_targets_limit: max_mount_targets_per_fs
          )
        end

        def extract_mount_targets_count(fs, fs_id, client)
          direct = extract_field(fs, :number_of_mount_targets)
          return direct.to_i unless direct.nil?

          if client.respond_to?(:describe_mount_targets)
            resp = client.describe_mount_targets(file_system_id: fs_id)
            targets = resp.respond_to?(:mount_targets) ? resp.mount_targets : []
            return Array(targets).size
          end

          0
        rescue StandardError
          0
        end

        def extract_size_breakdown(fs)
          size_obj = extract_field(fs, :size_in_bytes)
          return [0, 0, 0, 0] if size_obj.nil?
          return [size_obj.to_i, size_obj.to_i, 0, 0] if size_obj.is_a?(Numeric)

          total = extract_field(size_obj, :value).to_i
          ia = extract_field(size_obj, :value_in_ia).to_i
          archive = extract_field(size_obj, :value_in_archive).to_i
          raw_std = extract_field(size_obj, :value_in_standard)
          standard = if raw_std.nil?
                       [total - ia - archive, 0].max
                     else
                       raw_std.to_i
                     end
          total = standard + ia + archive if total.zero? && (standard.positive? || ia.positive? || archive.positive?)

          [total, standard, ia, archive]
        end

        def filter_by_target(all_usages, mount_fs_map, diagnostics)
          return all_usages if target_name.nil? || target_name.empty?

          matched = all_usages.select do |u|
            u.file_system_id == target_name || u.mount_name == target_name || u.name == target_name
          end

          if matched.empty? && mount_fs_map.value?(target_name)
            expected_fs_id = mount_fs_map.key(target_name)
            matched = all_usages.select { |u| u.file_system_id == expected_fs_id }
          end

          if matched.empty?
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-NOT-FOUND',
              severity: :error,
              summary: "EFS file system or mount '#{target_name}' was not found in region '#{region}'.",
              suggested_action: 'Verify the file system ID (fs-xxxx) or mount name in your Veltrunodefile.',
              evidence: { 'target' => target_name, 'region' => region }
            )
          end

          matched
        end

        def build_quotas_summary(all_usages, diagnostics)
          fs_used = all_usages.size
          fs_pct = calculate_percentage(fs_used, file_systems_limit)

          mt_used = all_usages.sum(&:mount_targets_count)
          mt_pct = calculate_percentage(mt_used, mount_targets_limit)

          max_mt_on_single_fs = all_usages.map(&:mount_targets_count).max || 0
          max_mt_pct = calculate_percentage(max_mt_on_single_fs, max_mount_targets_per_fs)

          check_quota_thresholds(fs_used, fs_pct, mt_used, mt_pct, diagnostics)

          {
            'file_systems' => {
              'used' => fs_used,
              'limit' => file_systems_limit,
              'usage_percent' => fs_pct
            },
            'mount_targets' => {
              'used' => mt_used,
              'limit' => mount_targets_limit,
              'max_per_file_system' => max_mount_targets_per_fs,
              'max_used_per_file_system' => max_mt_on_single_fs,
              'max_per_file_system_usage_percent' => max_mt_pct,
              'usage_percent' => mt_pct
            }
          }
        end

        def check_quota_thresholds(fs_used, fs_pct, mt_used, mt_pct, diagnostics)
          if fs_pct >= QUOTA_WARNING_THRESHOLD_PERCENT
            diagnostics << Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-QUOTA-WARNING',
              severity: :warning,
              summary: "Regional EFS file systems quota usage is at #{fs_pct}% (#{fs_used} / #{file_systems_limit}).",
              suggested_action: 'Request a quota increase via AWS Service Quotas or remove unused EFS file systems.',
              evidence: { 'metric' => 'file_systems', 'used' => fs_used, 'limit' => file_systems_limit,
                          'usage_percent' => fs_pct }
            )
          end

          return unless mt_pct >= QUOTA_WARNING_THRESHOLD_PERCENT

          diagnostics << Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-QUOTA-WARNING',
            severity: :warning,
            summary: "Regional EFS mount targets quota usage is at #{mt_pct}% (#{mt_used} / #{mount_targets_limit}).",
            suggested_action: 'Review EFS mount targets across VPCs or request a quota increase.',
            evidence: { 'metric' => 'mount_targets', 'used' => mt_used, 'limit' => mount_targets_limit,
                        'usage_percent' => mt_pct }
          )
        end

        def calculate_percentage(used, limit)
          return 0.0 if limit <= 0

          ((used.to_f / limit) * 100.0).round(2)
        end

        def extract_field(obj, key)
          if obj.respond_to?(key)
            obj.public_send(key)
          elsif obj.is_a?(Hash)
            obj[key] || obj[key.to_s]
          end
        end

        def resolve_efs_client
          return efs_client if efs_client

          begin
            require 'aws-sdk-efs' unless defined?(::Aws::EFS::Client)
            ::Aws::EFS::Client.new(region: region)
          rescue LoadError, StandardError
            nil
          end
        end
      end
    end
  end
end
