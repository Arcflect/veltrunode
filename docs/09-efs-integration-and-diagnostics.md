# EFS 統合と接続診断 (EFS Integration and Diagnostics)

## サポートされるマウントモード (Supported Modes)

1. **モード1 (Existing Access Point)**: 既存のアクセスポイントおよび既存のネットワークリソースを使用するモード。
2. **モード2 (Managed Access Point)**: 既存のファイルシステムを使用し、アクセスポイント（`AWS::EFS::AccessPoint`）はVeltrunode側で自動管理・生成するモード。
3. **モード3 (Fully Managed)**: 完全に管理されたEFSおよびネットワーク設定を新規生成するモード（初期フェーズ以降に計画）。

### モード2: 管理対象アクセスポイント (Managed Access Point) の定義

既存のファイルシステムID（`fs-xxxx`）を指定し、アクセスポイントのPOSIX UID/GIDおよびルートディレクトリ（作成時パーミッション・所有者）を宣言的に管理できます。

```ruby
efs_mount :shared_data do
  local_path "/mnt/shared"
  managed_access_point "fs-0123456789abcdef0" do
    root_directory path: "/lambda", owner_uid: 1000, owner_gid: 1000, permissions: "0755"
    posix_user uid: 1000, gid: 1000
  end
end

# またはトップレベルDSL
managed_access_point :workspace, "fs-0123456789abcdef0" do
  local_path "/mnt/workspace"
  posix_user uid: 1001, gid: 1001
end
```

コンパイル時に以下が自動実行されます：
- `AWS::EFS::AccessPoint` リソースの生成（POSIXユーザー、RootDirectory.Path、CreationInfo、タグ）
- Lambda Function の `FileSystemConfigs` への自動紐付け（`Fn::GetAtt: [AccessPointLogicalId, Arn]`）
- Lambda Function の `DependsOn` へのアクセスポイント依存関係の追加
- Lambda Execution Role への EFS クライアントIAMポリシー（`elasticfilesystem:ClientMount`, `ClientWrite`）の付与
- CloudFormation スタックの Outputs への AccessPoint ARN の出力

### セキュリティグループ作成ヘルパー (Security Group Helper)

Lambda 関数と EFS 間の NFS 通信に必要なセキュリティグループおよび通信許可ルール（TCP 2049）を自動生成できます。

```ruby
# トップレベルDSL
security_group_helper :shared_storage do
  vpc_id ref(:vpc_id) # パラメータ参照または既存リソース "vpc-xxxx"
  description "Security groups for shared storage" # 任意
end

# または efs_mount 内での定義
efs_mount :shared_data do
  local_path "/mnt/shared"
  managed_access_point "fs-0123456789abcdef0"
  security_group_helper vpc_id: "vpc-0123456789abcdef0"
end
```

コンパイル時に以下が自動実行されます：
- Lambda 側セキュリティグループ (`AWS::EC2::SecurityGroup`) の生成
- EFS 側セキュリティグループ (`AWS::EC2::SecurityGroup`) の生成
- Lambda → EFS: TCP 2049（NFS）アウトバウンド（Egress）許可ルール (`AWS::EC2::SecurityGroupEgress`) の生成
- EFS ← Lambda: TCP 2049（NFS）インバウンド（Ingress）許可ルール (`AWS::EC2::SecurityGroupIngress`) の生成
- VPC ID のパラメータ参照（`Ref: VpcId`）または既存リソース参照（リテラル `vpc-xxxx`、`Fn::ImportValue` 等）の解決
- Lambda Function の `VpcConfig.SecurityGroupIds` への自動紐付け
- CloudFormation スタックの Outputs への各セキュリティグループ ID の出力

### EFS ライフサイクルポリシー (Lifecycle Policies: IA / Archive 移行)

長期間アクセスされないログやキャッシュファイルを自動で低コストなストレージクラス（Infrequent Access / Archive）へ移行するため、`managed_access_point` または `efs_mount` 定義内で `lifecycle_policies`（`transition_to_ia`, `transition_to_archive`）を指定できます。

```ruby
efs_mount :shared_logs do
  local_path "/mnt/logs"
  managed_access_point "fs-0123456789abcdef0" do
    posix_user uid: 1000, gid: 1000
    lifecycle_policies transition_to_ia: "AFTER_30_DAYS",
                       transition_to_archive: "AFTER_90_DAYS"
  end
end

# ブロック構文またはトップレベル managed_access_point でも指定可能
managed_access_point :cache_storage, "fs-0123456789abcdef0" do
  local_path "/mnt/cache"
  lifecycle_policies do
    transition_to_ia :after_14_days
    transition_to_archive :after_60_days
  end
end
```

- **`transition_to_ia`**: Infrequent Access (IA) ストレージクラスへの移行期間（`AFTER_1_DAY`, `AFTER_7_DAYS`, `AFTER_14_DAYS`, `AFTER_30_DAYS`, `AFTER_60_DAYS`, `AFTER_90_DAYS`, `AFTER_180_DAYS`, `AFTER_270_DAYS`, `AFTER_365_DAYS`）。シンボル（`:after_30_days`）や日数指定も正規化されます。
- **`transition_to_archive`**: Archive ストレージクラスへの移行期間（同上。`transition_to_ia` と併用時は IA 移行期間以上の日数を指定する必要があります）。
- **CloudFormation `AWS::EFS::FileSystem` への反映**:
  `lifecycle_policies` が設定されたマウントでは、`Veltrunode::Compiler::CloudFormation::FileSystemCompiler` により `AWS::EFS::FileSystem`（論理ID: `#{MountName}FileSystem`）の `Properties.LifecyclePolicies`（`TransitionToIA`, `TransitionToArchive`）が生成されます。

### EFS スループットモード (Throughput Mode: Bursting / Provisioned / Elastic)

突発的な高トラフィックワークロードや定常的な高スループットを要求される処理において、`managed_access_point` または `efs_mount` 定義内で `throughput_mode`（`:bursting`, `:provisioned`, `:elastic`）およびプロビジョンドスループット値 `provisioned_throughput_in_mibps` を指定できます。

```ruby
# 1. Elastic スループットモードの指定
efs_mount :elastic_storage do
  local_path "/mnt/elastic"
  managed_access_point "fs-0123456789abcdef0" do
    throughput_mode :elastic
  end
end

# 2. Provisioned スループットモードと MiB/s 値の指定
managed_access_point :provisioned_storage, "fs-0123456789abcdef0" do
  local_path "/mnt/provisioned"
  throughput_mode :provisioned
  provisioned_throughput_in_mibps 200
end
```

- **`throughput_mode`**: EFS のスループットモード（`:bursting`, `:provisioned`, `:elastic`）。
- **`provisioned_throughput_in_mibps`（エイリアス: `provisioned_throughput`）**: `throughput_mode: :provisioned` 指定時のプロビジョンドスループット値（MiB/s、正の数値 `> 0`）。`:provisioned` 指定時に省略された場合や 0 以下の値、または `:elastic` / `:bursting` モードと同時指定された場合は `ValidationError` となります。
- **CloudFormation `AWS::EFS::FileSystem` への反映**:
  `Veltrunode::Compiler::CloudFormation::FileSystemCompiler` により `AWS::EFS::FileSystem` の `Properties.ThroughputMode` および `Properties.ProvisionedThroughputInMibps` に出力されます。

### EFS 自動バックアップ連携 (AWS Backup Automation: BackupVault / BackupPlan / BackupSelection)

ステートフルな EFS データの消失や破損に備え、定期的なスナップショットバックアップを自動構成するため、`managed_access_point` または `efs_mount` 定義内で `backup: true` またはバックアッププラン（`schedule`, `retention_days` 等）を指定できます。

```ruby
# 1. デフォルト設定（毎日 12:00 UTC、30日間保持）で自動バックアップを有効化
efs_mount :stateful_data, local_path: "/mnt/stateful", backup: true

# 2. スケジュールと保持期間を指定したバックアッププランの構成
efs_mount :shared_data do
  local_path "/mnt/shared"
  managed_access_point "fs-0123456789abcdef0" do
    posix_user uid: 1000, gid: 1000
    backup schedule: "cron(0 12 * * ? *)", retention_days: 30
  end
end

# 3. ブロック構文での詳細なバックアッププラン設定
managed_access_point :critical_storage, "fs-0123456789abcdef0" do
  local_path "/mnt/critical"
  backup do
    schedule "cron(0 3 * * ? *)"
    retention_days 90
    cold_storage_after_days 14
  end
end
```

- **`schedule`**: バックアップ実行スケジュール（`cron(...)` または `rate(...)` 形式。`backup: true` 時のデフォルト: `'cron(0 12 * * ? *)'`）。
- **`retention_days`**: バックアップスナップショットの保持日数（正の整数 `> 0`。`backup: true` 時のデフォルト: `30`）。
- **`cold_storage_after_days`（任意）**: コールドストレージへ移行するまでの日数（`retention_days` 未満の正の整数）。
- **生成される CloudFormation リソース（`Veltrunode::Compiler::CloudFormation::BackupCompiler`）**:
  - `AWS::Backup::BackupVault`（論理ID: `#{MountName}BackupVault`）
  - `AWS::Backup::BackupPlan`（論理ID: `#{MountName}BackupPlan`、`ScheduleExpression` および `Lifecycle.DeleteAfterDays` を設定）
  - `AWS::Backup::BackupSelection`（論理ID: `#{MountName}BackupSelection`、対象 EFS ファイルシステム ARN と IAM ロールを紐付け）
  - `AWS::IAM::Role`（論理ID: `#{MountName}BackupRole`、AWS Backup サービスロール）

### EFS メトリクス監視アラームヘルパー (CloudWatch Alarms: BurstCreditBalance / PercentIOLimit)

EFS のバーストクレジット枯渇や I/O 上限到達による Lambda 関数のハングアップを未然に検知するため、`managed_access_point` または `efs_mount` 定義内で `alarms`（エイリアス: `efs_alarms`, `efs_alarm_helper`）を指定して `BurstCreditBalance` および `PercentIOLimit` の CloudWatch アラームを自動生成できます。

```ruby
# 1. デフォルト閾値（BurstCreditBalance <= 1 GiB、PercentIOLimit >= 80%）でアラームを有効化
efs_mount :shared_data, local_path: "/mnt/shared", alarms: true

# 2. バーストクレジット残量の警告閾値や I/O 上限率、SNS 通知トピックを指定
efs_mount :work_data do
  local_path "/mnt/data"
  managed_access_point "fs-0123456789abcdef0" do
    posix_user uid: 1000, gid: 1000
    alarms burst_credit_balance: 500_000_000,
           percent_io_limit: 85,
           topic: ref(:efs_alert_topic)
  end
end

# 3. ブロック構文またはバイト単位文字列での詳細なアラーム設定
managed_access_point :critical_storage, "fs-0123456789abcdef0" do
  local_path "/mnt/critical"
  alarms do
    burst_credit_balance "2GB"
    percent_io_limit 90
    topic ref(:ops_topic)
  end
end
```

- **`burst_credit_balance`（エイリアス: `burst_credit_balance_threshold`, `burst_credit_threshold`）**:
  - バーストクレジット残量（`AWS/EFS` の `BurstCreditBalance` メトリクス、単位: Bytes）の低下警告閾値。
  - デフォルト閾値: `1_073_741_824`（1 GiB）、統計: `Minimum`、比較演算子: `LessThanOrEqualToThreshold`、期間: `300` 秒。正の数値または `'500MB'`, `'10GB'` 等のバイト単位文字列を指定可能。
- **`percent_io_limit`（エイリアス: `percent_io_limit_threshold`, `io_limit_threshold`）**:
  - I/O 上限到達率（`AWS/EFS` の `PercentIOLimit` メトリクス、単位: `%`）の警告閾値（`1..100`）。
  - デフォルト閾値: `80`（80%）、統計: `Average`、比較演算子: `GreaterThanOrEqualToThreshold`、期間: `300` 秒。
- **生成される CloudFormation リソース（`Veltrunode::Compiler::CloudFormation::EfsAlarmCompiler`）**:
  - `AWS::CloudWatch::Alarm`（論理ID: `#{MountName}BurstCreditBalanceAlarm` および `#{MountName}PercentIOLimitAlarm`、`Dimensions: [{ Name: 'FileSystemId', Value: ... }]`）。
  - `topic` にパラメータ参照（`ref(:efs_alert_topic)` 等）が指定された場合、CloudFormation の `Parameters` に SNS トピック ARN パラメータが自動登録されます。

### EFS KMS カスタマーマネージドキー暗号化 (KMS Customer-Managed Key Encryption at Rest)

コンプライアンス要件により AWS マネージドキーではなく顧客管理の KMS キー（CMK）による保存時暗号化が必須となるケースに対応するため、`efs_mount` または `managed_access_point` 定義内で `encrypted: true` および `kms_key_id`（エイリアス: `kms_key`, `kms_key_arn`）を指定できます。

```ruby
# 1. efs_mount での KMS カスタマーマネージドキー ARN 指定
efs_mount :cmk_data,
          local_path: "/mnt/cmk",
          encrypted: true,
          kms_key_id: "arn:aws:kms:ap-northeast-1:123456789012:key/12345678-1234-1234-1234-123456789012"

# 2. パラメータ参照（ref）やブロック構文での指定
managed_access_point :secure_storage do
  local_path "/mnt/secure"
  encrypted true
  kms_key_id ref(:efs_cmk_arn)
  posix_user uid: 1000, gid: 1000
end
```

- **`encrypted`**: 保存時暗号化の有効/無効（`true` / `false`）。`kms_key_id` を指定した場合、`encrypted` が未指定でも自動的に `true` に設定されます（`encrypted: false` と `kms_key_id` の同時指定は `ValidationError` となります）。
- **`kms_key_id`（エイリアス: `kms_key`, `kms_key_arn`）**: KMS カスタマーマネージドキーの ARN（`arn:aws:kms:...`）、キー ID（UUID）、エイリアス（`alias/...`）、またはパラメータ参照（`ref(:...)`）。不正な形式の文字列はモデル初期化時に `ValidationError` として検証されます。
- **CloudFormation `AWS::EFS::FileSystem` および IAM ロールへの反映**:
  - `AWS::EFS::FileSystem` の `Properties.Encrypted` および `Properties.KmsKeyId` に出力されます。
  - 当該 EFS をマウントする Lambda 関数の実行ロール（`AWS::IAM::Role`）に対し、指定された KMS キーへの暗号化・復号権限（`kms:Decrypt`, `kms:DescribeKey`, `kms:Encrypt`, `kms:GenerateDataKey*`, `kms:ReEncrypt*`）が最小特権で自動追加されます。

## 静的チェック項目 (Static Checks)

- ローカルのマウントパスが `/mnt/` で始まっていること。
- 関数に対して VPC サブネットおよびセキュリティグループが設定されていること。
- アクセスポイントの ARN の形式およびリージョンが互換であること。
- 重複するマウントパスが定義されていないこと。
- 高負荷なファイル処理ワークロードが想定される場合、タイムアウト値および同時実行数に関する警告を表示すること。

## AWS 接続検証チェック (AWS-Aware Checks)

`efs verify` コマンドは、読み取り専用のAWS APIを使用して以下を検査します。

- アクセスポイントおよびファイルシステムのステータス。
- ファイルシステムと Lambda の VPC 構成の一致。
- 接続可能なアベイラビリティゾーン（AZ）内のマウントターゲットの有無。
- Lambda 側のセキュリティグループから TCP ポート 2049（NFS）へのアウトバウンド（Egress）の許可。
- EFS 側のセキュリティグループにて、Lambda 側のセキュリティグループからの TCP ポート 2049（NFS）インバウンド（Ingress）の許可。
- 判定可能な範囲におけるルートテーブルおよびサブネットの状態。
- アクセスポイントのルートディレクトリおよび POSIX ユーザー/グループ ID（UID/GID）。
- Lambda 実行ロールにおける EFS クライアントのIAM操作権限。
- 暗号化設定およびバックアップ設定に関する警告メッセージ。
- EFS CloudWatch アラーム（`BurstCreditBalance` / `PercentIOLimit`）の設定有無およびアラーム状態（`OK` / `ALARM`）の確認（`VLT-EFS-ALARM-STATE`, `VLT-EFS-ALARM-MISSING`）。

## EFS ストレージサイズ・クォータ確認 (`veltrunode efs quota`)

`veltrunode efs quota [NAME]` コマンドは、`Veltrunode::AWS::Inspectors::EfsQuotaInspector` により EFS API（`DescribeFileSystems` 等）を呼び出し、ファイルシステムごとのストレージクラス別サイズ内訳およびリージョン内のクォータ状況を表形式（または `--format json` での構造化 JSON）で表示します。

- **ストレージクラス別サイズ内訳**:
  - `Total Size`: ファイルシステム全体のサイズ（`size_in_bytes.value`）
  - `Standard`: EFS Standard ストレージクラスのサイズ（`size_in_bytes.value_in_standard`）
  - `IA`: EFS Infrequent Access (IA) ストレージクラスのサイズ（`size_in_bytes.value_in_ia`）
  - `Archive`: EFS Archive ストレージクラスのサイズ（`size_in_bytes.value_in_archive`）
  - `Size Limit`: ファイルシステムあたりの容量上限（256 TiB）
  - `Mount Targets`: ファイルシステムに作成されているマウントターゲット数 / 上限数（32）
- **リージョン内 EFS クォータ**:
  - `File Systems`: リージョン内の EFS ファイルシステム数 / アカウント上限（デフォルト: 1,000）および使用率（%）
  - `Mount Targets (Total)`: リージョン内のマウントターゲット総数 / 上限（デフォルト: 1,000）および使用率（%）
  - `Mount Targets (Max per File System)`: 単一ファイルシステムあたりの最大マウントターゲット数 / 上限（32）
  - クォータ使用率が 80% 以上に達している場合は、`VLT-EFS-QUOTA-WARNING` 警告診断が出力されます。

## EFS I/O パフォーマンスベンチマーク (`veltrunode efs bench`)

`veltrunode efs bench <function_name>` コマンドは、`Veltrunode::AWS::EfsBenchmarker` により対象 Lambda 関数の EFS マウントパス上で読み書きベンチマークを実行し、I/O レイテンシやスループットを表形式（または `--format json` での構造化 JSON）で出力します。

- **測定ワークロード**:
  - **4KB ランダム I/O (`random_4kb`)**: 4,096 バイト単位でのランダム書込・読込の平均レイテンシ（`ms`）、IOPS、およびスループット（`MB/s`）を測定します。
  - **1MB シーケンシャル I/O (`sequential_1mb`)**: 1,048,576 バイト（1 MB）単位でのシーケンシャル書込・読込の平均レイテンシ（`ms`）およびスループット（`MB/s`）を測定します。
- **自動クリーンアップ**:
  - ベンチマーク実行時に作成された一時テストディレクトリ・ファイル（`.veltrunode_bench_*`）および一時ベンチマーク用 Lambda 関数は、測定完了後（エラー発生時を含む）に `ensure` ブロックで確実に自動削除されます。

## 診断の制限事項 (Diagnostic Limitations)

ネットワークACL、DNSの挙動、一時的なサービス障害、アプリケーションレベルでのファイルロック、およびPOSIXの詳細な挙動については、関数の実行前に100%確実に検証することはできません。接続診断は、安易に成功を保証するのではなく、検証されたエビデンス（証拠）と確信度をレポートとして出力します。

## エラー出力例

```text
VLT-EFS-2049-INGRESS: EFS security group sg-efs does not allow TCP 2049 from Lambda security group sg-lambda.
Suggested action: add an ingress rule scoped to sg-lambda, or reference a security group that already provides it.
```
