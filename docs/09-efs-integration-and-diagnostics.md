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

## 診断の制限事項 (Diagnostic Limitations)

ネットワークACL、DNSの挙動、一時的なサービス障害、アプリケーションレベルでのファイルロック、およびPOSIXの詳細な挙動については、関数の実行前に100%確実に検証することはできません。接続診断は、安易に成功を保証するのではなく、検証されたエビデンス（証拠）と確信度をレポートとして出力します。

## エラー出力例

```text
VLT-EFS-2049-INGRESS: EFS security group sg-efs does not allow TCP 2049 from Lambda security group sg-lambda.
Suggested action: add an ingress rule scoped to sg-lambda, or reference a security group that already provides it.
```
