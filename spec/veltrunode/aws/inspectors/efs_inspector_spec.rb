# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/model'
require 'veltrunode/aws/inspectors/efs_inspector'

RSpec.describe Veltrunode::AWS::Inspectors::EfsInspector do
  let(:efs_mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_data',
      access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-1234567890abcdef0',
      local_path: '/mnt/shared',
      posix_expectations: { uid: 1000, gid: 1000 }
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      :processor,
      handler: 'app.handler',
      vpc_reference: {
        security_group_ids: ['sg-lambda123'],
        subnet_ids: %w[subnet-aaa subnet-bbb]
      },
      mounts: ['shared_data']
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'efs-test-app',
      region: 'ap-northeast-1',
      stage: 'dev',
      mounts: [efs_mount],
      functions: [function]
    )
  end

  # AWS SDK クライアントのモック
  let(:mock_efs_client) { double('Aws::EFS::Client') }
  let(:mock_ec2_client) { double('Aws::EC2::Client') }
  let(:mock_iam_client) { double('Aws::IAM::Client') }

  # デフォルトの正常系モックデータ
  let(:ap_response) do
    double(
      'AccessPointsResponse',
      access_points: [
        double(
          'AccessPoint',
          access_point_id: 'fsap-1234567890abcdef0',
          life_cycle_state: 'available',
          file_system_id: 'fs-12345678',
          posix_user: double('PosixUser', uid: 1000, gid: 1000, secondary_gids: []),
          root_directory: double('RootDirectory', path: '/shared')
        )
      ]
    )
  end

  let(:fs_response) do
    double(
      'FileSystemsResponse',
      file_systems: [
        double(
          'FileSystem',
          file_system_id: 'fs-12345678',
          life_cycle_state: 'available',
          encrypted: true,
          number_of_mount_targets: 2
        )
      ]
    )
  end

  let(:mount_targets_response) do
    double(
      'MountTargetsResponse',
      mount_targets: [
        double(
          'MountTargetA',
          mount_target_id: 'fsmt-1111',
          file_system_id: 'fs-12345678',
          subnet_id: 'subnet-aaa',
          vpc_id: 'vpc-main',
          availability_zone_name: 'ap-northeast-1a',
          availability_zone_id: nil,
          life_cycle_state: 'available'
        ),
        double(
          'MountTargetB',
          mount_target_id: 'fsmt-2222',
          file_system_id: 'fs-12345678',
          subnet_id: 'subnet-bbb',
          vpc_id: 'vpc-main',
          availability_zone_name: 'ap-northeast-1c',
          availability_zone_id: nil,
          life_cycle_state: 'available'
        )
      ]
    )
  end

  let(:subnets_response) do
    double(
      'SubnetsResponse',
      subnets: [
        double(
          'SubnetA',
          subnet_id: 'subnet-aaa',
          vpc_id: 'vpc-main',
          availability_zone: 'ap-northeast-1a',
          availability_zone_name: nil,
          state: 'available',
          cidr_block: '10.0.1.0/24'
        ),
        double(
          'SubnetB',
          subnet_id: 'subnet-bbb',
          vpc_id: 'vpc-main',
          availability_zone: 'ap-northeast-1c',
          availability_zone_name: nil,
          state: 'available',
          cidr_block: '10.0.2.0/24'
        )
      ]
    )
  end

  let(:lambda_sg_response) do
    double(
      'SecurityGroupsResponse',
      security_groups: [
        double(
          'SecurityGroup',
          group_id: 'sg-lambda123',
          ip_permissions_egress: [
            double(
              'IpPermission',
              ip_protocol: '-1', # All outbound allowed
              from_port: nil,
              to_port: nil
            )
          ]
        )
      ]
    )
  end

  let(:efs_sg_ids_response) do
    double('MountTargetSecurityGroupsResponse', security_groups: ['sg-efs456'])
  end

  let(:efs_sg_response) do
    double(
      'SecurityGroupsResponse',
      security_groups: [
        double(
          'SecurityGroup',
          group_id: 'sg-efs456',
          ip_permissions: [
            double(
              'IpPermission',
              ip_protocol: 'tcp',
              from_port: 2049,
              to_port: 2049,
              user_id_group_pairs: [double('UserIdGroupPair', group_id: 'sg-lambda123')],
              ip_ranges: []
            )
          ]
        )
      ]
    )
  end

  let(:route_tables_response) do
    double(
      'RouteTablesResponse',
      route_tables: [
        double(
          'RouteTable',
          route_table_id: 'rtb-1234',
          routes: [
            double(
              'Route',
              gateway_id: 'local',
              target_id: nil,
              destination_cidr_block: '10.0.0.0/16',
              state: 'active'
            )
          ]
        )
      ]
    )
  end

  let(:backup_policy_response) do
    double(
      'BackupPolicyResponse',
      backup_policy: double('BackupPolicy', status: 'ENABLED')
    )
  end

  before do
    allow(mock_efs_client).to receive(:describe_access_points).and_return(ap_response)
    allow(mock_efs_client).to receive(:describe_file_systems).and_return(fs_response)
    allow(mock_efs_client).to receive(:describe_mount_targets).and_return(mount_targets_response)
    allow(mock_efs_client).to receive(:describe_mount_target_security_groups).and_return(efs_sg_ids_response)
    allow(mock_efs_client).to receive(:describe_backup_policy).and_return(backup_policy_response)

    allow(mock_ec2_client).to receive(:describe_subnets).and_return(subnets_response)
    allow(mock_ec2_client).to receive(:describe_security_groups)
      .with(group_ids: ['sg-lambda123']).and_return(lambda_sg_response)
    allow(mock_ec2_client).to receive(:describe_security_groups)
      .with(group_ids: ['sg-efs456']).and_return(efs_sg_response)
    allow(mock_ec2_client).to receive(:describe_route_tables).and_return(route_tables_response)
  end

  subject(:inspector) do
    described_class.new(
      application,
      target_name: 'shared_data',
      efs_client: mock_efs_client,
      ec2_client: mock_ec2_client,
      iam_client: mock_iam_client
    )
  end

  describe '全チェック正常通過時の検証' do
    it '全11項目が実行され、エラーなし（success? == true）かつ HIGH confidence でレポートを返却すること' do
      report = inspector.inspect

      expect(report.success?).to be true
      expect(report.has_warnings?).to be false
      expect(report.overall_confidence).to eq('HIGH')
      expect(report.target_name).to eq('shared_data')
      expect(report.function_name).to eq('processor')
      expect(report.access_point_id).to eq('fsap-1234567890abcdef0')
      expect(report.file_system_id).to eq('fs-12345678')
      expect(report.diagnostics).to be_empty
      expect(report.limitations).to eq(described_class::LIMITATIONS)

      # チェック結果一覧の検証
      check_names = report.checks.map(&:name)
      expect(check_names).to include(
        'access_point_status',
        'file_system_status',
        'vpc_consistency',
        'mount_target_reachability',
        'security_group_egress',
        'security_group_ingress',
        'subnets_and_routes',
        'posix_and_root_directory',
        'lambda_iam_permissions',
        'encryption_at_rest',
        'backup_policy'
      )
      expect(report.checks.all?(&:passed?)).to be true
    end

    it '読み取り専用 API のみを使用し、変更 API は一切呼び出さないこと' do
      inspector.inspect

      expect(mock_efs_client).to have_received(:describe_access_points).at_least(:once)
      expect(mock_efs_client).to have_received(:describe_file_systems).at_least(:once)
      expect(mock_efs_client).to have_received(:describe_mount_targets).at_least(:once)
      expect(mock_efs_client).to have_received(:describe_mount_target_security_groups).at_least(:once)
      expect(mock_efs_client).to have_received(:describe_backup_policy).at_least(:once)
      expect(mock_ec2_client).to have_received(:describe_subnets).at_least(:once)
      expect(mock_ec2_client).to have_received(:describe_security_groups).at_least(:once)
      expect(mock_ec2_client).to have_received(:describe_route_tables).at_least(:once)
    end
  end

  describe 'ターゲット解決の検証' do
    it 'function 名で指定した場合に紐付く EFS マウントを自動解決すること' do
      func_inspector = described_class.new(
        application,
        target_name: 'processor',
        efs_client: mock_efs_client,
        ec2_client: mock_ec2_client,
        iam_client: mock_iam_client
      )
      report = func_inspector.inspect
      expect(report.success?).to be true
      expect(report.target_name).to eq('shared_data')
      expect(report.function_name).to eq('processor')
    end

    it '引数なしでマウントが1つの場合に自動選択されること' do
      auto_inspector = described_class.new(
        application,
        target_name: nil,
        efs_client: mock_efs_client,
        ec2_client: mock_ec2_client,
        iam_client: mock_iam_client
      )
      report = auto_inspector.inspect
      expect(report.success?).to be true
      expect(report.target_name).to eq('shared_data')
    end

    it '存在しない名前が指定された場合は VLT-EFS-NOT-FOUND エラーを返すこと' do
      invalid_inspector = described_class.new(
        application,
        target_name: 'unknown_mount',
        efs_client: mock_efs_client,
        ec2_client: mock_ec2_client
      )
      report = invalid_inspector.inspect
      expect(report.success?).to be false
      expect(report.diagnostics.first.code).to eq('VLT-EFS-NOT-FOUND')
    end
  end

  describe '各チェックの異常系・警告系検証' do
    context 'アクセスポイントが available でない場合' do
      let(:ap_response) do
        double(
          'AccessPointsResponse',
          access_points: [
            double(
              'AccessPoint',
              access_point_id: 'fsap-1234567890abcdef0',
              life_cycle_state: 'creating',
              file_system_id: 'fs-12345678'
            )
          ]
        )
      end

      it 'VLT-EFS-AP-STATE エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-AP-STATE' }
        expect(diag).not_to be_nil
        expect(diag.summary).to include('creating state (expected \'available\')')
        expect(diag.suggested_action).to include('Wait for the access point')
      end
    end

    context 'ファイルシステムが available でない場合' do
      let(:fs_response) do
        double(
          'FileSystemsResponse',
          file_systems: [
            double(
              'FileSystem',
              file_system_id: 'fs-12345678',
              life_cycle_state: 'deleting',
              encrypted: true
            )
          ]
        )
      end

      it 'VLT-EFS-FS-STATE エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-FS-STATE' }
        expect(diag).not_to be_nil
        expect(diag.summary).to include('deleting state')
      end
    end

    context 'Lambda と EFS の VPC が一致しない場合' do
      let(:subnets_response) do
        double(
          'SubnetsResponse',
          subnets: [
            double(
              'Subnet',
              subnet_id: 'subnet-aaa',
              vpc_id: 'vpc-lambda-other',
              availability_zone: 'ap-northeast-1a',
              availability_zone_name: nil,
              state: 'available'
            )
          ]
        )
      end

      it 'VLT-EFS-VPC-MISMATCH エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-VPC-MISMATCH' }
        expect(diag).not_to be_nil
        expect(diag.summary).to include('VPC mismatch')
        expect(diag.evidence['lambda_vpc_id']).to eq('vpc-lambda-other')
        expect(diag.evidence['efs_vpc_ids']).to eq(['vpc-main'])
      end
    end

    context '到達可能な AZ にマウントターゲットが存在しない場合' do
      let(:subnets_response) do
        double(
          'SubnetsResponse',
          subnets: [
            double(
              'Subnet',
              subnet_id: 'subnet-isolated',
              vpc_id: 'vpc-main',
              availability_zone: 'ap-northeast-1d', # 1d has no mount target
              availability_zone_name: nil,
              state: 'available'
            )
          ]
        )
      end

      it 'VLT-EFS-MOUNT-TARGET エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-MOUNT-TARGET' }
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:error)
        expect(diag.summary).to include('No available EFS mount targets found in Lambda Availability Zones')
      end
    end

    context '一部の AZ にのみマウントターゲットが存在する場合' do
      let(:subnets_response) do
        double(
          'SubnetsResponse',
          subnets: [
            double(
              'SubnetA',
              subnet_id: 'subnet-aaa',
              vpc_id: 'vpc-main',
              availability_zone: 'ap-northeast-1a',
              availability_zone_name: nil,
              state: 'available'
            ),
            double(
              'SubnetD',
              subnet_id: 'subnet-isolated',
              vpc_id: 'vpc-main',
              availability_zone: 'ap-northeast-1d',
              availability_zone_name: nil,
              state: 'available'
            )
          ]
        )
      end

      it 'VLT-EFS-MOUNT-TARGET 警告を報告すること' do
        report = inspector.inspect
        expect(report.has_warnings?).to be true
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-MOUNT-TARGET' }
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.summary).to include('missing in some Lambda Availability Zones: ap-northeast-1d')
      end
    end

    context 'Lambda 側のセキュリティグループで TCP 2049 Egress が許可されていない場合' do
      let(:lambda_sg_response) do
        double(
          'SecurityGroupsResponse',
          security_groups: [
            double(
              'SecurityGroup',
              group_id: 'sg-lambda123',
              ip_permissions_egress: [
                double(
                  'IpPermission',
                  ip_protocol: 'tcp',
                  from_port: 80,
                  to_port: 80
                )
              ]
            )
          ]
        )
      end

      it 'VLT-EFS-2049-EGRESS エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-2049-EGRESS' }
        expect(diag).not_to be_nil
        expect(diag.summary).to include('do not allow outbound TCP 2049 (NFS) traffic')
        expect(diag.suggested_action).to include('Add an egress rule allowing outbound TCP 2049')
      end
    end

    context 'EFS 側のセキュリティグループで Lambda SG からの TCP 2049 Ingress が許可されていない場合' do
      let(:efs_sg_response) do
        double(
          'SecurityGroupsResponse',
          security_groups: [
            double(
              'SecurityGroup',
              group_id: 'sg-efs456',
              ip_permissions: [
                double(
                  'IpPermission',
                  ip_protocol: 'tcp',
                  from_port: 2049,
                  to_port: 2049,
                  user_id_group_pairs: [double('UserIdGroupPair', group_id: 'sg-other-client')],
                  ip_ranges: []
                )
              ]
            )
          ]
        )
      end

      it '受け入れ基準に合致する VLT-EFS-2049-INGRESS エラーを出力すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-2049-INGRESS' }
        expect(diag).not_to be_nil
        expect(diag.summary).to eq(
          'EFS security group sg-efs456 does not allow TCP 2049 from Lambda security group sg-lambda123.'
        )
        expect(diag.suggested_action).to eq(
          'add an ingress rule scoped to sg-lambda123, or reference a security group that already provides it.'
        )
        expect(diag.aws_resource_id).to eq('sg-efs456')
      end
    end

    context 'POSIX UID/GID の不一致がある場合' do
      let(:ap_response) do
        double(
          'AccessPointsResponse',
          access_points: [
            double(
              'AccessPoint',
              access_point_id: 'fsap-1234567890abcdef0',
              life_cycle_state: 'available',
              file_system_id: 'fs-12345678',
              posix_user: double('PosixUser', uid: 2000, gid: 2000), # Mismatch with expected 1000
              root_directory: double('RootDirectory', path: '/shared')
            )
          ]
        )
      end

      it 'VLT-EFS-POSIX-UID および VLT-EFS-POSIX-GID エラーを報告すること' do
        report = inspector.inspect
        expect(report.success?).to be false
        uid_diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-POSIX-UID' }
        gid_diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-POSIX-GID' }
        expect(uid_diag).not_to be_nil
        expect(uid_diag.summary).to include('configured UID 2000 does not match expected UID 1000')
        expect(gid_diag).not_to be_nil
        expect(gid_diag.summary).to include('configured GID 2000 does not match expected GID 1000')
      end
    end

    context 'EFS ファイルシステムの暗号化が無効な場合' do
      let(:fs_response) do
        double(
          'FileSystemsResponse',
          file_systems: [
            double(
              'FileSystem',
              file_system_id: 'fs-12345678',
              life_cycle_state: 'available',
              encrypted: false, # Encryption disabled
              number_of_mount_targets: 2
            )
          ]
        )
      end

      it 'VLT-EFS-ENCRYPTION-DISABLED 警告を報告すること' do
        report = inspector.inspect
        expect(report.has_warnings?).to be true
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-ENCRYPTION-DISABLED' }
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.summary).to include('not encrypted at rest')
        expect(diag.suggested_action).to include('Enable encryption at rest')
      end
    end

    context 'EFS ファイルシステムの自動バックアップが無効な場合' do
      let(:backup_policy_response) do
        double(
          'BackupPolicyResponse',
          backup_policy: double('BackupPolicy', status: 'DISABLED')
        )
      end

      it 'VLT-EFS-BACKUP-DISABLED 警告を報告すること' do
        report = inspector.inspect
        expect(report.has_warnings?).to be true
        diag = report.diagnostics.find { |d| d.code == 'VLT-EFS-BACKUP-DISABLED' }
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.summary).to include('Automatic backup policy is disabled')
        expect(diag.suggested_action).to include('Enable automatic backup policy')
      end
    end
  end
end
