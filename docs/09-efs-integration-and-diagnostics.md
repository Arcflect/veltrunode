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
