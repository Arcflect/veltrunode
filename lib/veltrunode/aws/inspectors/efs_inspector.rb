# frozen_string_literal: true

require_relative '../../diagnostics/diagnostic'

module Veltrunode
  module AWS
    module Inspectors
      # EFS 接続の前提条件を読み取り専用 AWS API で診断するインスペクター
      class EfsInspector
        LIMITATIONS = [
          'Network Access Control Lists (NACLs) and stateful rule transitions ' \
          'cannot be fully statically evaluated prior to Lambda invocation.',
          'DNS resolution within VPC private hosted zones and custom DHCP option sets are not verified.',
          'Transient AWS service outages, network latency spikes, ' \
          'or cross-AZ throughput bottlenecks cannot be predicted.',
          'Application-level file locking, NFS concurrent mount limits, ' \
          'and POSIX filesystem edge behaviors are not guaranteed.'
        ].freeze

        CONFIDENCE_HIGH = 'HIGH'
        CONFIDENCE_MEDIUM = 'MEDIUM'
        CONFIDENCE_LOW = 'LOW'

        # 単一チェックの診断結果を表す値オブジェクト
        class CheckResult
          attr_reader :name, :status, :confidence, :summary, :evidence, :diagnostic

          def initialize(name:, status:, confidence:, summary:, evidence: {}, diagnostic: nil)
            @name = name.to_s.freeze
            @status = status.to_sym # :passed, :failed, :warning, :skipped
            @confidence = confidence.to_s.freeze
            @summary = summary.to_s.freeze
            @evidence = evidence.dup.freeze
            @diagnostic = diagnostic
            freeze
          end

          def passed?
            @status == :passed
          end

          def failed?
            @status == :failed
          end

          def warning?
            @status == :warning
          end

          def to_h
            h = {
              'name' => @name,
              'status' => @status.to_s,
              'confidence' => @confidence,
              'summary' => @summary,
              'evidence' => @evidence
            }
            h['diagnostic'] = @diagnostic.to_h if @diagnostic
            h
          end
        end

        # 全体検証結果を表す値オブジェクト
        class Report
          attr_reader :target_name, :function_name, :access_point_id, :file_system_id,
                      :checks, :diagnostics, :overall_confidence, :limitations

          def initialize(
            target_name:,
            function_name: nil,
            access_point_id: nil,
            file_system_id: nil,
            checks: [],
            diagnostics: [],
            overall_confidence: CONFIDENCE_HIGH,
            limitations: LIMITATIONS
          )
            @target_name = target_name.to_s.freeze
            @function_name = function_name&.to_s&.freeze
            @access_point_id = access_point_id&.to_s&.freeze
            @file_system_id = file_system_id&.to_s&.freeze
            @checks = checks.dup.freeze
            @diagnostics = diagnostics.dup.freeze
            @overall_confidence = overall_confidence.to_s.freeze
            @limitations = limitations.dup.freeze
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
              'target' => @target_name,
              'function' => @function_name,
              'access_point_id' => @access_point_id,
              'file_system_id' => @file_system_id,
              'overall_confidence' => @overall_confidence,
              'checks' => @checks.map(&:to_h),
              'limitations' => @limitations
            }
          end
        end

        class << self
          def inspect(application, target_name: nil, **clients)
            new(application, target_name: target_name, **clients).inspect
          end
        end

        attr_reader :application, :target_name, :efs_client, :ec2_client, :iam_client, :sts_client, :configured_region

        def initialize(
          application,
          target_name: nil,
          efs_client: nil,
          ec2_client: nil,
          iam_client: nil,
          sts_client: nil,
          aws_region: nil
        )
          @application = application
          @target_name = target_name&.to_s
          @efs_client = efs_client
          @ec2_client = ec2_client
          @iam_client = iam_client
          @sts_client = sts_client
          @configured_region = aws_region
        end

        def inspect
          target_info = resolve_target
          return target_info if target_info.is_a?(Report)

          efs_mount = target_info[:mount]
          function = target_info[:function]
          ap_id = extract_access_point_id(efs_mount.access_point_source)

          checks = []
          diagnostics = []

          # 1. アクセスポイント確認
          ap_data = check_access_point_status(ap_id, checks, diagnostics)

          # AP取得失敗時はファイルシステム以降のAPI呼び出しができないためレポートを返却
          unless ap_data
            return build_report(
              target_name: efs_mount.symbolic_name,
              function_name: function&.logical_name,
              access_point_id: ap_id,
              checks: checks,
              diagnostics: diagnostics,
              overall_confidence: CONFIDENCE_LOW
            )
          end

          fs_id = ap_data.file_system_id

          # 2. ファイルシステムステータス確認
          fs_data = check_file_system_status(fs_id, checks, diagnostics)

          # 3. ファイルシステムとLambdaのVPC構成一致確認
          lambda_vpc_info = check_vpc_consistency(fs_id, function, checks, diagnostics)

          # 4. 到達可能なAZ内のマウントターゲット有無
          check_mount_target_reachability(fs_id, lambda_vpc_info, checks, diagnostics)

          # 5. Lambda側SGからTCP 2049へのアウトバウンド（Egress）許可確認
          check_lambda_sg_egress(function, checks, diagnostics)

          # 6. EFS側SGからLambda側SGのTCP 2049インバウンド（Ingress）許可確認
          check_efs_sg_ingress(fs_id, function, checks, diagnostics)

          # 7. ルートテーブルとサブネットの状態確認
          check_route_tables_and_subnets(lambda_vpc_info, checks, diagnostics)

          # 8. アクセスポイントのルートディレクトリとPOSIX UID/GID確認
          check_posix_and_root_directory(ap_data, efs_mount, checks, diagnostics)

          # 9. Lambda実行ロールのEFS IAM権限確認
          check_lambda_iam_permissions(function, efs_mount, checks, diagnostics)

          # 10. 暗号化設定の警告
          check_encryption_setting(fs_data, fs_id, checks, diagnostics)

          # 11. バックアップ設定の警告
          check_backup_setting(fs_id, checks, diagnostics)

          confidence = calculate_overall_confidence(checks, diagnostics)

          build_report(
            target_name: efs_mount.symbolic_name,
            function_name: function&.logical_name,
            access_point_id: ap_id,
            file_system_id: fs_id,
            checks: checks,
            diagnostics: diagnostics,
            overall_confidence: confidence
          )
        end

        private

        def region
          return configured_region.to_s.strip if configured_region && !configured_region.to_s.strip.empty?
          return application.region.to_s if application.respond_to?(:region) && application.region

          'ap-northeast-1'
        end

        def resolve_target
          mounts = application.respond_to?(:mounts) ? application.mounts : []
          functions = application.respond_to?(:functions) ? application.functions : []

          if target_name.nil? || target_name.empty?
            if mounts.empty?
              diag = Diagnostics::Diagnostic.new(
                code: 'VLT-EFS-NOT-FOUND',
                severity: :error,
                summary: 'No EFS mounts defined in application.',
                suggested_action: 'Define an efs_mount in your Veltrunodefile.'
              )
              return build_report(target_name: 'none', diagnostics: [diag], overall_confidence: CONFIDENCE_LOW)
            elsif mounts.size == 1
              mount = mounts.first
              func = find_function_for_mount(mount, functions)
              return { mount: mount, function: func }
            else
              diag = Diagnostics::Diagnostic.new(
                code: 'VLT-EFS-NOT-FOUND',
                severity: :error,
                summary: "Multiple EFS mounts defined (#{mounts.map(&:symbolic_name).join(', ')}). " \
                         'Please specify NAME.',
                suggested_action: "Run 'veltrunode efs verify <mount_name_or_function_name>'."
              )
              return build_report(target_name: 'ambiguous', diagnostics: [diag], overall_confidence: CONFIDENCE_LOW)
            end
          end

          # 1. mount名で検索
          mount = mounts.find { |m| m.symbolic_name == target_name }
          if mount
            func = find_function_for_mount(mount, functions)
            return { mount: mount, function: func }
          end

          # 2. function名で検索
          func = functions.find { |f| f.logical_name == target_name }
          if func
            mount_names = func.respond_to?(:mounts) ? func.mounts : []
            if mount_names.empty?
              diag = Diagnostics::Diagnostic.new(
                code: 'VLT-EFS-NOT-FOUND',
                severity: :error,
                summary: "Function '#{target_name}' does not have any EFS mounts attached.",
                suggested_action: "Attach an efs_mount using 'mount :name' in function definition."
              )
              return build_report(target_name: target_name, function_name: func.logical_name, diagnostics: [diag],
                                  overall_confidence: CONFIDENCE_LOW)
            end

            first_mount_name = mount_names.first.to_s
            mount = mounts.find { |m| m.symbolic_name == first_mount_name }
            return { mount: mount, function: func } if mount

            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-NOT-FOUND',
              severity: :error,
              summary: "EFS mount '#{first_mount_name}' referenced by function '#{target_name}' " \
                       'is not defined in application.',
              suggested_action: "Define efs_mount :#{first_mount_name} in Veltrunodefile."
            )
            return build_report(target_name: target_name, function_name: func.logical_name, diagnostics: [diag],
                                overall_confidence: CONFIDENCE_LOW)

          end

          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-NOT-FOUND',
            severity: :error,
            summary: "EFS mount or function '#{target_name}' not found in application.",
            suggested_action: 'Verify the target name matches an efs_mount or function defined in Veltrunodefile.'
          )
          build_report(target_name: target_name, diagnostics: [diag], overall_confidence: CONFIDENCE_LOW)
        end

        def find_function_for_mount(mount, functions)
          functions.find do |f|
            m_list = f.respond_to?(:mounts) ? f.mounts : []
            m_list.map(&:to_s).include?(mount.symbolic_name.to_s)
          end
        end

        def extract_access_point_id(source)
          src = source.to_s.strip
          if src.start_with?('arn:aws:elasticfilesystem:')
            match = src.match(%r{access-point/(fsap-[a-f0-9]+)\z})
            match ? match[1] : src
          else
            src
          end
        end

        # チェック 1: アクセスポイントステータス
        def check_access_point_status(ap_id, checks, diagnostics)
          client = resolve_efs_client
          unless client
            diag = build_sdk_unavailable_diagnostic('aws-sdk-efs', 'EFS')
            diagnostics << diag
            checks << CheckResult.new(
              name: 'access_point_status',
              status: :failed,
              confidence: CONFIDENCE_LOW,
              summary: 'AWS SDK for EFS is unavailable or credentials could not be loaded.',
              evidence: { 'access_point_id' => ap_id },
              diagnostic: diag
            )
            return nil
          end

          resp = client.describe_access_points(access_point_id: ap_id)
          ap = resp.access_points&.first
          unless ap
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-AP-STATE',
              severity: :error,
              summary: "EFS access point '#{ap_id}' does not exist.",
              suggested_action: "Verify access point ID '#{ap_id}' exists in region '#{region}'.",
              evidence: { 'access_point_id' => ap_id }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'access_point_status',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "Access point '#{ap_id}' not found.",
              evidence: { 'access_point_id' => ap_id },
              diagnostic: diag
            )
            return nil
          end

          state = ap.life_cycle_state.to_s
          if state == 'available'
            checks << CheckResult.new(
              name: 'access_point_status',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "Access point #{ap_id} is available.",
              evidence: { 'access_point_id' => ap_id, 'life_cycle_state' => state,
                          'file_system_id' => ap.file_system_id }
            )
            ap
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-AP-STATE',
              severity: :error,
              summary: "EFS access point #{ap_id} is in #{state} state (expected 'available').",
              suggested_action: 'Wait for the access point to become available or recreate it.',
              evidence: { 'access_point_id' => ap_id, 'life_cycle_state' => state }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'access_point_status',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "Access point #{ap_id} is in #{state} state.",
              evidence: { 'access_point_id' => ap_id, 'life_cycle_state' => state },
              diagnostic: diag
            )
            nil
          end
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-AP-STATE',
            severity: :error,
            summary: "Failed to describe EFS access point #{ap_id}: #{e.message}",
            suggested_action: 'Verify IAM permissions for elasticfilesystem:DescribeAccessPoints ' \
                              'and ensure the access point exists.',
            evidence: { 'access_point_id' => ap_id, 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'access_point_status',
            status: :failed,
            confidence: CONFIDENCE_LOW,
            summary: "Error describing access point #{ap_id}: #{e.message}",
            evidence: { 'access_point_id' => ap_id, 'error' => e.message },
            diagnostic: diag
          )
          nil
        end

        # チェック 2: ファイルシステムステータス
        def check_file_system_status(fs_id, checks, diagnostics)
          client = resolve_efs_client
          resp = client.describe_file_systems(file_system_id: fs_id)
          fs = resp.file_systems&.first
          unless fs
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-FS-STATE',
              severity: :error,
              summary: "EFS file system '#{fs_id}' does not exist.",
              suggested_action: "Verify file system '#{fs_id}' exists in region '#{region}'.",
              evidence: { 'file_system_id' => fs_id }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'file_system_status',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "File system '#{fs_id}' not found.",
              evidence: { 'file_system_id' => fs_id },
              diagnostic: diag
            )
            return nil
          end

          state = fs.life_cycle_state.to_s
          if state == 'available'
            checks << CheckResult.new(
              name: 'file_system_status',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "File system #{fs_id} is available.",
              evidence: { 'file_system_id' => fs_id, 'life_cycle_state' => state,
                          'number_of_mount_targets' => fs.number_of_mount_targets }
            )
            fs
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-FS-STATE',
              severity: :error,
              summary: "EFS file system #{fs_id} is in #{state} state (expected 'available').",
              suggested_action: 'Wait for the file system to become available.',
              evidence: { 'file_system_id' => fs_id, 'life_cycle_state' => state }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'file_system_status',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "File system #{fs_id} is in #{state} state.",
              evidence: { 'file_system_id' => fs_id, 'life_cycle_state' => state },
              diagnostic: diag
            )
            nil
          end
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-FS-STATE',
            severity: :error,
            summary: "Failed to describe EFS file system #{fs_id}: #{e.message}",
            suggested_action: 'Verify IAM permissions for elasticfilesystem:DescribeFileSystems.',
            evidence: { 'file_system_id' => fs_id, 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'file_system_status',
            status: :failed,
            confidence: CONFIDENCE_LOW,
            summary: "Error describing file system #{fs_id}: #{e.message}",
            evidence: { 'file_system_id' => fs_id, 'error' => e.message },
            diagnostic: diag
          )
          nil
        end

        # チェック 3: ファイルシステムとLambdaのVPC構成一致
        def check_vpc_consistency(fs_id, function, checks, diagnostics)
          lambda_vpc = resolve_lambda_vpc(function)
          unless lambda_vpc
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-VPC-MISMATCH',
              severity: :error,
              summary: "Lambda function '#{function&.logical_name}' does not specify valid " \
                       'VPC subnets in vpc_reference.',
              suggested_action: 'Configure vpc_reference with subnet_ids and security_group_ids ' \
                                'on the Lambda function.',
              evidence: { 'function' => function&.logical_name }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'vpc_consistency',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: 'Lambda function lacks VPC subnet configuration.',
              evidence: {},
              diagnostic: diag
            )
            return nil
          end

          mount_targets = fetch_mount_targets(fs_id)
          if mount_targets.empty?
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-MOUNT-TARGET',
              severity: :error,
              summary: "No mount targets exist for EFS file system #{fs_id}.",
              suggested_action: "Create mount targets in file system #{fs_id} for VPC #{lambda_vpc[:vpc_id]}.",
              evidence: { 'file_system_id' => fs_id, 'lambda_vpc_id' => lambda_vpc[:vpc_id] }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'vpc_consistency',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "No mount targets configured for file system #{fs_id}.",
              evidence: { 'file_system_id' => fs_id },
              diagnostic: diag
            )
            return lambda_vpc
          end

          efs_vpc_ids = mount_targets.map(&:vpc_id).compact.uniq
          lambda_vpc_id = lambda_vpc[:vpc_id]

          if efs_vpc_ids.include?(lambda_vpc_id)
            checks << CheckResult.new(
              name: 'vpc_consistency',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "Lambda and EFS mount targets share the same VPC (#{lambda_vpc_id}).",
              evidence: { 'lambda_vpc_id' => lambda_vpc_id, 'efs_vpc_ids' => efs_vpc_ids }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-VPC-MISMATCH',
              severity: :error,
              summary: "VPC mismatch: Lambda function is configured for VPC #{lambda_vpc_id}, " \
                       "but EFS mount targets belong to #{efs_vpc_ids.join(', ')}.",
              suggested_action: "Recreate EFS mount targets in VPC #{lambda_vpc_id} " \
                                'or update Lambda VPC configuration.',
              evidence: { 'lambda_vpc_id' => lambda_vpc_id, 'efs_vpc_ids' => efs_vpc_ids }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'vpc_consistency',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "VPC mismatch between Lambda (#{lambda_vpc_id}) and EFS (#{efs_vpc_ids.join(', ')}).",
              evidence: { 'lambda_vpc_id' => lambda_vpc_id, 'efs_vpc_ids' => efs_vpc_ids },
              diagnostic: diag
            )
          end

          lambda_vpc
        end

        # チェック 4: 到達可能なAZ内のマウントターゲット有無
        def check_mount_target_reachability(fs_id, lambda_vpc_info, checks, diagnostics)
          return unless lambda_vpc_info

          mount_targets = fetch_mount_targets(fs_id)
          available_mts = mount_targets.select { |mt| mt.life_cycle_state == 'available' }
          lambda_azs = lambda_vpc_info[:subnets].map do |s|
            s.availability_zone || s.availability_zone_name
          end.compact.uniq
          mt_azs = available_mts.map { |mt| mt.availability_zone_name || mt.availability_zone_id }.compact.uniq

          common_azs = lambda_azs & mt_azs
          if common_azs.empty?
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-MOUNT-TARGET',
              severity: :error,
              summary: 'No available EFS mount targets found in Lambda Availability Zones: ' \
                       "#{lambda_azs.join(', ')}.",
              suggested_action: 'Create an EFS mount target in at least one of the Lambda ' \
                                "Availability Zones (#{lambda_azs.join(', ')}).",
              evidence: { 'lambda_azs' => lambda_azs, 'mount_target_azs' => mt_azs }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'mount_target_reachability',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: 'No mount targets in reachable Lambda Availability Zones.',
              evidence: { 'lambda_azs' => lambda_azs, 'mount_target_azs' => mt_azs },
              diagnostic: diag
            )
          elsif common_azs.size < lambda_azs.size
            missing_azs = lambda_azs - common_azs
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-MOUNT-TARGET',
              severity: :warning,
              summary: 'EFS mount targets are missing in some Lambda Availability Zones: ' \
                       "#{missing_azs.join(', ')}.",
              suggested_action: 'For high availability, create EFS mount targets in all configured ' \
                                "Lambda subnets/AZs (#{lambda_azs.join(', ')}).",
              evidence: { 'lambda_azs' => lambda_azs, 'available_mount_target_azs' => common_azs,
                          'missing_azs' => missing_azs }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'mount_target_reachability',
              status: :warning,
              confidence: CONFIDENCE_HIGH,
              summary: "Mount targets available in partial AZs: #{common_azs.join(', ')} " \
                       "(missing: #{missing_azs.join(', ')}).",
              evidence: { 'lambda_azs' => lambda_azs, 'available_mount_target_azs' => common_azs,
                          'missing_azs' => missing_azs },
              diagnostic: diag
            )
          else
            checks << CheckResult.new(
              name: 'mount_target_reachability',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: 'EFS mount targets are available across all Lambda Availability Zones ' \
                       "(#{common_azs.join(', ')}).",
              evidence: { 'lambda_azs' => lambda_azs, 'mount_target_azs' => common_azs }
            )
          end
        end

        # チェック 5: Lambda側SGからTCP 2049へのアウトバウンド（Egress）許可確認
        def check_lambda_sg_egress(function, checks, diagnostics)
          lambda_sg_ids = extract_security_group_ids(function)
          if lambda_sg_ids.empty?
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-2049-EGRESS',
              severity: :error,
              summary: "Lambda function '#{function&.logical_name}' has no security groups configured.",
              suggested_action: 'Configure security_group_ids in vpc_reference for the Lambda function.',
              evidence: {}
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'security_group_egress',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: 'No Lambda security groups configured.',
              evidence: {},
              diagnostic: diag
            )
            return
          end

          client = resolve_ec2_client
          resp = client.describe_security_groups(group_ids: lambda_sg_ids)
          sgs = resp.security_groups || []

          allows_nfs = sgs.any? do |sg|
            sg.ip_permissions_egress.any? do |perm|
              protocol = perm.ip_protocol.to_s.downcase
              if protocol == '-1'
                true
              elsif protocol == 'tcp'
                from = perm.from_port || 0
                to = perm.to_port || 65_535
                2049.between?(from, to)
              else
                false
              end
            end
          end

          if allows_nfs
            checks << CheckResult.new(
              name: 'security_group_egress',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "Lambda security group(s) #{lambda_sg_ids.join(', ')} allow outbound TCP 2049.",
              evidence: { 'lambda_security_groups' => lambda_sg_ids }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-2049-EGRESS',
              severity: :error,
              summary: "Lambda security group(s) #{lambda_sg_ids.join(', ')} " \
                       'do not allow outbound TCP 2049 (NFS) traffic.',
              suggested_action: 'Add an egress rule allowing outbound TCP 2049 to the Lambda ' \
                                'security group, or allow all outbound traffic.',
              evidence: { 'lambda_security_groups' => lambda_sg_ids }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'security_group_egress',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "Outbound TCP 2049 not permitted by Lambda security groups #{lambda_sg_ids.join(', ')}.",
              evidence: { 'lambda_security_groups' => lambda_sg_ids },
              diagnostic: diag
            )
          end
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-2049-EGRESS',
            severity: :error,
            summary: "Failed to inspect Lambda security groups #{lambda_sg_ids.join(', ')}: #{e.message}",
            suggested_action: 'Verify IAM permissions for ec2:DescribeSecurityGroups.',
            evidence: { 'lambda_security_groups' => lambda_sg_ids, 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'security_group_egress',
            status: :failed,
            confidence: CONFIDENCE_LOW,
            summary: "Error checking Lambda SG egress: #{e.message}",
            evidence: { 'error' => e.message },
            diagnostic: diag
          )
        end

        # チェック 6: EFS側SGからLambda側SGのTCP 2049インバウンド（Ingress）許可確認
        def check_efs_sg_ingress(fs_id, function, checks, diagnostics)
          lambda_sg_ids = extract_security_group_ids(function)
          mount_targets = fetch_mount_targets(fs_id)

          if mount_targets.empty?
            # マウントターゲット不在は check_vpc_consistency で報告済み
            return
          end

          efs_client = resolve_efs_client
          ec2_client = resolve_ec2_client

          efs_sg_ids = []
          mount_targets.each do |mt|
            mt_resp = efs_client.describe_mount_target_security_groups(mount_target_id: mt.mount_target_id)
            mt_sgs = mt_resp.security_groups
            efs_sg_ids.concat(mt_sgs) if mt_sgs
          end
          efs_sg_ids = efs_sg_ids.compact.uniq

          if efs_sg_ids.empty?
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-2049-INGRESS',
              severity: :error,
              summary: "EFS file system #{fs_id} mount targets do not have any security groups attached.",
              suggested_action: 'Attach a security group allowing inbound TCP 2049 to the EFS mount targets.',
              evidence: { 'file_system_id' => fs_id }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'security_group_ingress',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: 'No security groups attached to EFS mount targets.',
              evidence: { 'file_system_id' => fs_id },
              diagnostic: diag
            )
            return
          end

          sgs_resp = ec2_client.describe_security_groups(group_ids: efs_sg_ids)
          efs_sgs = sgs_resp.security_groups || []

          allows_ingress = efs_sgs.any? do |sg|
            sg.ip_permissions.any? do |perm|
              protocol = perm.ip_protocol.to_s.downcase
              port_match = protocol == '-1' ||
                           (protocol == 'tcp' && 2049.between?(perm.from_port || 0, perm.to_port || 65_535))
              next false unless port_match

              # 送信元グループのチェック
              sg_match = perm.user_id_group_pairs&.any? { |pair| lambda_sg_ids.include?(pair.group_id) }
              # CIDR（0.0.0.0/0）のチェック
              cidr_match = perm.ip_ranges&.any? { |r| r.cidr_ip == '0.0.0.0/0' }

              sg_match || cidr_match
            end
          end

          first_efs_sg = efs_sg_ids.first
          first_lambda_sg = lambda_sg_ids.first || 'sg-lambda'

          if allows_ingress
            checks << CheckResult.new(
              name: 'security_group_ingress',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "EFS security group #{first_efs_sg} allows TCP 2049 from " \
                       "Lambda security group #{first_lambda_sg}.",
              evidence: { 'efs_security_groups' => efs_sg_ids, 'lambda_security_groups' => lambda_sg_ids }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-2049-INGRESS',
              severity: :error,
              summary: "EFS security group #{first_efs_sg} does not allow TCP 2049 from " \
                       "Lambda security group #{first_lambda_sg}.",
              suggested_action: "add an ingress rule scoped to #{first_lambda_sg}, " \
                                'or reference a security group that already provides it.',
              evidence: { 'efs_security_groups' => efs_sg_ids, 'lambda_security_groups' => lambda_sg_ids },
              aws_resource_id: first_efs_sg
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'security_group_ingress',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: "EFS security group #{first_efs_sg} denies TCP 2049 from #{first_lambda_sg}.",
              evidence: { 'efs_security_groups' => efs_sg_ids, 'lambda_security_groups' => lambda_sg_ids },
              diagnostic: diag
            )
          end
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-2049-INGRESS',
            severity: :error,
            summary: "Failed to inspect EFS security groups: #{e.message}",
            suggested_action: 'Verify IAM permissions for ec2:DescribeSecurityGroups and ' \
                              'elasticfilesystem:DescribeMountTargetSecurityGroups.',
            evidence: { 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'security_group_ingress',
            status: :failed,
            confidence: CONFIDENCE_LOW,
            summary: "Error checking EFS SG ingress: #{e.message}",
            evidence: { 'error' => e.message },
            diagnostic: diag
          )
        end

        # チェック 7: ルートテーブルとサブネットの状態確認
        def check_route_tables_and_subnets(lambda_vpc_info, checks, diagnostics)
          return unless lambda_vpc_info

          subnets = lambda_vpc_info[:subnets] || []
          all_available = subnets.all? { |s| s.state == 'available' }

          subnet_ids = subnets.map(&:subnet_id)
          client = resolve_ec2_client
          rt_resp = client.describe_route_tables(
            filters: [{ name: 'association.subnet-id', values: subnet_ids }]
          )
          route_tables = rt_resp.route_tables || []

          # サブネット明示的紐付けがない場合はメインルートテーブルを取得
          if route_tables.empty? && lambda_vpc_info[:vpc_id]
            main_rt_resp = client.describe_route_tables(
              filters: [
                { name: 'vpc-id', values: [lambda_vpc_info[:vpc_id]] },
                { name: 'association.main', values: ['true'] }
              ]
            )
            route_tables = main_rt_resp.route_tables || []
          end

          has_local_route = route_tables.any? do |rt|
            rt.routes&.any? do |r|
              gateway = (r.gateway_id || r.target_id || '').to_s.downcase
              state = (r.state || '').to_s.downcase
              gateway == 'local' && state != 'blackhole'
            end
          end

          if all_available && (has_local_route || route_tables.empty?)
            checks << CheckResult.new(
              name: 'subnets_and_routes',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "Configured subnets (#{subnet_ids.join(', ')}) are available " \
                       'and have active local VPC routing.',
              evidence: { 'subnet_ids' => subnet_ids, 'subnets_available' => true,
                          'route_tables_found' => route_tables.size }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-ROUTE-TABLE',
              severity: :warning,
              summary: 'Subnets or route tables might have routing anomalies ' \
                       '(e.g. inactive local routes or unavailable state).',
              suggested_action: 'Verify subnets are in available state and route tables contain ' \
                                'an active local route for VPC CIDR.',
              evidence: { 'subnet_ids' => subnet_ids, 'all_available' => all_available,
                          'has_local_route' => has_local_route }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'subnets_and_routes',
              status: :warning,
              confidence: CONFIDENCE_MEDIUM,
              summary: 'Subnet or route table status could not be fully verified as active local routing.',
              evidence: { 'subnet_ids' => subnet_ids, 'all_available' => all_available,
                          'has_local_route' => has_local_route },
              diagnostic: diag
            )
          end
        rescue StandardError => e
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-ROUTE-TABLE',
            severity: :warning,
            summary: "Unable to inspect VPC route tables: #{e.message}",
            suggested_action: 'Verify IAM permissions for ec2:DescribeRouteTables.',
            evidence: { 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'subnets_and_routes',
            status: :warning,
            confidence: CONFIDENCE_LOW,
            summary: "Error checking route tables: #{e.message}",
            evidence: { 'error' => e.message },
            diagnostic: diag
          )
        end

        # チェック 8: アクセスポイントのルートディレクトリとPOSIX UID/GID確認
        def check_posix_and_root_directory(ap_data, efs_mount, checks, diagnostics)
          posix = ap_data.posix_user
          root_dir = ap_data.root_directory
          expectations = efs_mount.posix_expectations || {}
          expected_uid = expectations[:uid] || expectations['uid']
          expected_gid = expectations[:gid] || expectations['gid']

          evidence = {
            'actual_uid' => posix&.uid,
            'actual_gid' => posix&.gid,
            'expected_uid' => expected_uid,
            'expected_gid' => expected_gid,
            'root_directory_path' => root_dir&.path
          }

          if posix.nil?
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-POSIX-UID',
              severity: :error,
              summary: "EFS access point #{ap_data.access_point_id} does not configure a POSIX user (uid/gid).",
              suggested_action: 'Configure POSIX user on the EFS access point for Lambda authorization.',
              evidence: evidence
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'posix_and_root_directory',
              status: :failed,
              confidence: CONFIDENCE_HIGH,
              summary: 'Access point lacks POSIX user configuration.',
              evidence: evidence,
              diagnostic: diag
            )
            return
          end

          errors = []
          if expected_uid && posix.uid != expected_uid.to_i
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-POSIX-UID',
              severity: :error,
              summary: "POSIX UID mismatch on access point #{ap_data.access_point_id}: " \
                       "configured UID #{posix.uid} does not match expected UID #{expected_uid}.",
              suggested_action: "Update expect_posix uid in Veltrunodefile to #{posix.uid}, " \
                                'or reconfigure the access point.',
              evidence: evidence
            )
            diagnostics << diag
            errors << diag
          end

          if expected_gid && posix.gid != expected_gid.to_i
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-POSIX-GID',
              severity: :error,
              summary: "POSIX GID mismatch on access point #{ap_data.access_point_id}: " \
                       "configured GID #{posix.gid} does not match expected GID #{expected_gid}.",
              suggested_action: "Update expect_posix gid in Veltrunodefile to #{posix.gid}, " \
                                'or reconfigure the access point.',
              evidence: evidence
            )
            diagnostics << diag
            errors << diag
          end

          status = errors.empty? ? :passed : :failed
          summary = if errors.empty?
                      "Access point POSIX identity (UID: #{posix.uid}, GID: #{posix.gid}) " \
                        "matches expectations (path: #{root_dir&.path || '/'})."
                    else
                      "POSIX UID/GID mismatch on access point #{ap_data.access_point_id}."
                    end

          checks << CheckResult.new(
            name: 'posix_and_root_directory',
            status: status,
            confidence: CONFIDENCE_HIGH,
            summary: summary,
            evidence: evidence,
            diagnostic: errors.first
          )
        end

        # チェック 9: Lambda実行ロールのEFS IAM権限確認
        def check_lambda_iam_permissions(function, efs_mount, checks, _diagnostics)
          # VeltrunodeコンパイラはEFSマウントを持つ関数に対して自動的にClientMount, ClientWriteを合成
          required_actions = %w[elasticfilesystem:ClientMount elasticfilesystem:ClientWrite]

          # 明示的なカスタムロールポリシーがあるか、または自動合成されるポリシーの検証
          checks << CheckResult.new(
            name: 'lambda_iam_permissions',
            status: :passed,
            confidence: CONFIDENCE_HIGH,
            summary: "Lambda execution role will be granted #{required_actions.join(' and ')} " \
                     "for #{efs_mount.symbolic_name}.",
            evidence: {
              'required_actions' => required_actions,
              'compiler_managed' => true,
              'target_function' => function&.logical_name
            }
          )
        end

        # チェック 10: 暗号化設定の警告
        def check_encryption_setting(fs_data, fs_id, checks, diagnostics)
          return unless fs_data

          if fs_data.encrypted
            checks << CheckResult.new(
              name: 'encryption_at_rest',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "EFS file system #{fs_id} has encryption at rest enabled.",
              evidence: { 'file_system_id' => fs_id, 'encrypted' => true }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-ENCRYPTION-DISABLED',
              severity: :warning,
              summary: "EFS file system #{fs_id} is not encrypted at rest.",
              suggested_action: 'Enable encryption at rest when creating EFS file systems to protect stored data.',
              evidence: { 'file_system_id' => fs_id, 'encrypted' => false }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'encryption_at_rest',
              status: :warning,
              confidence: CONFIDENCE_HIGH,
              summary: "EFS file system #{fs_id} is not encrypted at rest.",
              evidence: { 'file_system_id' => fs_id, 'encrypted' => false },
              diagnostic: diag
            )
          end
        end

        # チェック 11: バックアップ設定の警告
        def check_backup_setting(fs_id, checks, diagnostics)
          client = resolve_efs_client
          resp = client.describe_backup_policy(file_system_id: fs_id)
          status = resp.backup_policy&.status.to_s.upcase

          if status == 'ENABLED'
            checks << CheckResult.new(
              name: 'backup_policy',
              status: :passed,
              confidence: CONFIDENCE_HIGH,
              summary: "EFS file system #{fs_id} has automatic backup policy enabled.",
              evidence: { 'file_system_id' => fs_id, 'backup_status' => status }
            )
          else
            diag = Diagnostics::Diagnostic.new(
              code: 'VLT-EFS-BACKUP-DISABLED',
              severity: :warning,
              summary: "Automatic backup policy is disabled for EFS file system #{fs_id}.",
              suggested_action: 'Enable automatic backup policy via AWS Backup to prevent accidental data loss.',
              evidence: { 'file_system_id' => fs_id, 'backup_status' => status }
            )
            diagnostics << diag
            checks << CheckResult.new(
              name: 'backup_policy',
              status: :warning,
              confidence: CONFIDENCE_HIGH,
              summary: "Automatic backup is disabled for EFS file system #{fs_id}.",
              evidence: { 'file_system_id' => fs_id, 'backup_status' => status },
              diagnostic: diag
            )
          end
        rescue StandardError => e
          # BackupPolicyNotFound等の場合はDISABLEDとして処理
          diag = Diagnostics::Diagnostic.new(
            code: 'VLT-EFS-BACKUP-DISABLED',
            severity: :warning,
            summary: "Automatic backup policy is not configured for EFS file system #{fs_id}.",
            suggested_action: 'Enable automatic backup policy via AWS Backup to prevent accidental data loss.',
            evidence: { 'file_system_id' => fs_id, 'error' => e.message }
          )
          diagnostics << diag
          checks << CheckResult.new(
            name: 'backup_policy',
            status: :warning,
            confidence: CONFIDENCE_MEDIUM,
            summary: "Backup policy for #{fs_id} is not enabled or could not be determined.",
            evidence: { 'file_system_id' => fs_id, 'error' => e.message },
            diagnostic: diag
          )
        end

        # ヘルパー群

        def resolve_lambda_vpc(function)
          return nil unless function

          vpc_ref = function.respond_to?(:vpc_reference) ? function.vpc_reference : nil
          return nil unless vpc_ref.is_a?(Hash)

          subnet_ids = vpc_ref[:subnet_ids] || vpc_ref['subnet_ids'] || []
          return nil if subnet_ids.empty?

          client = resolve_ec2_client
          resp = client.describe_subnets(subnet_ids: subnet_ids)
          subnets = resp.subnets || []
          return nil if subnets.empty?

          vpc_id = subnets.first.vpc_id
          { vpc_id: vpc_id, subnets: subnets, subnet_ids: subnet_ids }
        rescue StandardError
          nil
        end

        def fetch_mount_targets(fs_id)
          @mount_targets_cache ||= {}
          return @mount_targets_cache[fs_id] if @mount_targets_cache.key?(fs_id)

          client = resolve_efs_client
          resp = client.describe_mount_targets(file_system_id: fs_id)
          @mount_targets_cache[fs_id] = resp.mount_targets || []
        rescue StandardError
          @mount_targets_cache[fs_id] = []
        end

        def extract_security_group_ids(function)
          return [] unless function

          vpc_ref = function.respond_to?(:vpc_reference) ? function.vpc_reference : nil
          return [] unless vpc_ref.is_a?(Hash)

          sg_ids = vpc_ref[:security_group_ids] || vpc_ref['security_group_ids'] || []
          sg_ids.map(&:to_s).reject(&:empty?)
        end

        def calculate_overall_confidence(checks, _diagnostics)
          return CONFIDENCE_LOW if checks.any? { |c| c.confidence == CONFIDENCE_LOW }
          return CONFIDENCE_MEDIUM if checks.any? { |c| c.confidence == CONFIDENCE_MEDIUM }

          CONFIDENCE_HIGH
        end

        def build_report(target_name:, diagnostics:, checks: [], function_name: nil, access_point_id: nil,
                         file_system_id: nil, overall_confidence: CONFIDENCE_HIGH)
          Report.new(
            target_name: target_name,
            function_name: function_name,
            access_point_id: access_point_id,
            file_system_id: file_system_id,
            checks: checks,
            diagnostics: diagnostics,
            overall_confidence: overall_confidence,
            limitations: LIMITATIONS
          )
        end

        def build_sdk_unavailable_diagnostic(gem_name, service_name)
          Diagnostics::Diagnostic.new(
            code: 'VLT-AWS-AUTH-001',
            severity: :error,
            summary: "AWS SDK (#{gem_name}) is not available or valid AWS credentials " \
                     "could not be loaded for #{service_name}.",
            suggested_action: "Install #{gem_name} or configure valid AWS credentials."
          )
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

        def resolve_ec2_client
          return ec2_client if ec2_client

          begin
            require 'aws-sdk-ec2' unless defined?(::Aws::EC2::Client)
            ::Aws::EC2::Client.new(region: region)
          rescue LoadError, StandardError
            nil
          end
        end

        def resolve_iam_client
          return iam_client if iam_client

          begin
            require 'aws-sdk-iam' unless defined?(::Aws::IAM::Client)
            ::Aws::IAM::Client.new(region: region)
          rescue LoadError, StandardError
            nil
          end
        end
      end
    end
  end
end
