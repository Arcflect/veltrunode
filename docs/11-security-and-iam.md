# セキュリティと IAM (Security and IAM)

## 設計原則 (Principles)

- デフォルトで最小特権（least privilege）を適用します。
- 具体的な ARN を生成できる箇所では、リソース指定へのワイルドカード（`*`）の使用を避けます。
- Lambda 実行ロールと Scheduler 呼び出しロールを明確に分離します。
- 付与されるすべての権限は、plan（計画）およびマニフェストファイルにて視認可能な状態にします。
- 本番ステージのポリシーでは、アクションに対するワイルドカードの指定、パブリックストレージの使用、ログ保持期間の設定漏れ、および DLQ の未設定に対して拒否（エラー）を設定できます。

## ステージポリシーと本番ポリシーパック (Stage Policies & Production Policy Pack)

ステージ（`production`, `staging` 等）に応じて厳格なセキュリティ要件を強制するための `StagePolicy` および組み込みの **本番ポリシーパック (Production Policy Pack)** を提供します。
`production`（または `prod`）ステージでは、デフォルトで本番ポリシーパックが自動適用され、セキュリティのベストプラクティスが強制されます。

バリデーションフェーズにおいてポリシー違反が検出された場合、エラー Diagnostic（`VLT-IAM-001`, `VLT-IAM-002`, `VLT-SCHED-002`, `VLT-LOG-001` 等）および明確な修正ガイド（`Suggested action`）が出力され、CLI は終了コード `8`（`EXIT_POLICY_VIOLATION`）で安全に停止します。

### 本番ポリシーパック (Production Policy Pack) のルール一覧

本番ポリシーパックでは、以下の4つのセキュリティルールがデフォルトで有効化（`true`）されます。

| ルール名 | 設定型 | デフォルト（production） | 説明 | 違反時コード | 修正ガイドの例 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `deny_wildcard_actions` | boolean | `true` | IAM アクションに対するワイルドカード（`*`, `:*`）の指定を拒否します | `VLT-IAM-001` | 明示的な IAM アクションを指定する |
| `require_dlq` | boolean | `true` | すべてのスケジュール定義に対して DLQ（デッドレターキュー）の指定を必須とします | `VLT-SCHED-002` | スケジュールに `dlq`（SQS キュー ARN）を設定する |
| `require_log_retention` | boolean | `true` | CloudWatch Logs のログ保持期間（`retention_days`）の設定を必須とします | `VLT-LOG-001` | defaults に `logs retention_days: 30` 等を指定する |
| `deny_public_storage` | boolean | `true` | S3 等のストレージ定義におけるパブリックアクセス設定を拒否します | `VLT-IAM-002` | ストレージのケーパビリティからパブリックアクセス設定を削除する |

### DSL での設定例

#### 1. 本番ステージでのデフォルト適用（追加設定不要）

`stage "production"` を指定するだけで、本番ポリシーパックが自動的に有効になります。

```ruby
Veltrunode.application "my-secure-app" do
  stage "production"
  account_constraint "123456789012"
  region "ap-northeast-1"

  # defaults でログ保持期間を設定（require_log_retention 準拠）
  defaults do
    logs retention_days: 30
  end
end
```

#### 2. ポリシーパックの明示的指定とカスタマイズ (`policy_pack`)

別のステージに本番ポリシーパックを適用したり、特定のルールのみをオーバーライド（例外許可）できます。

```ruby
Veltrunode.application "staging-secure-app" do
  stage "staging"

  # staging 環境に本番ポリシーパックを適用しつつ、パブリックストレージのみ例外許可
  policy_pack :production do
    deny_public_storage false
  end
end
```

#### 3. カスタムポリシーの定義 (`stage_policy` / `custom_policy`)

ステージごとに独自のポリシールールを定義することも可能です。

```ruby
Veltrunode.application "custom-app" do
  stage "qa"

  stage_policy :qa do
    deny_wildcard_actions true
    require_log_retention true
  end
end
```

## ケーパビリティの展開 (Capability Expansion)

高水準の「ケーパビリティ」は、設定の利便性を高めるための宣言であり、背後で隠された独自の魔法ではありません。各ケーパビリティは、生成された出力ファイル内にドキュメント化されているバージョン管理されたマッピングルールに従って展開されます。必要に応じて、ユーザーは明示的な IAM アクションを直接指定することもできます。

## 分散トレーシングと IAM 権限 (Tracing and IAM Permissions)

Lambda 関数で X-Ray トレーシング（`tracing: :active` または `tracing: :pass_through`）が有効化された場合、Lambda 実行ロールに AWS 管理ポリシー `AWSXRayDaemonWriteAccess`（`arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess`）が自動的にアタッチされます。

- **最小特権の維持**:
  トレーシングが設定されていない関数には本ポリシーは付与されず、必要な関数にのみスコープが限定されます。
- **権限内容**:
  Lambda 内蔵の X-Ray デーモンがセグメントおよびテレメトリデータを AWS X-Ray サービスへ安全にストリーミングするための権限（`xray:PutTraceSegments`, `xray:PutTelemetryRecords`, `xray:GetSamplingRules`, `xray:GetSamplingTargets`）が付与されます。

## Lambda Insights と IAM 権限 (Lambda Insights and IAM Permissions)

Lambda 関数で Lambda Insights 拡張モニタリング（`insights: true` または `defaults` ブロックでの指定）が有効化された場合、Lambda 実行ロールに AWS 管理ポリシー `CloudWatchLambdaInsightsExecutionRolePolicy`（`arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy`）が自動的にアタッチされます。

- **最小特権の維持**:
  Lambda Insights が有効化されていない関数には本ポリシーは付与されず、必要な関数にのみスコープが限定されます。
- **権限内容**:
  Lambda Insights 拡張レイヤーが詳細なシステムメトリクス（CPU、メモリ使用率、ネットワークトラフィック等）を CloudWatch Logs（`/aws/lambda-insights` ロググループ）へ書き込むための権限（`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` 等）が付与されます。

## Lambda Function URL の認証とリソースベースポリシー (Lambda Function URL Authentication & Resource Policy)

Lambda Function URL（`function_url`）を構成する際、認証種別（`auth_type`）に応じてリソースベースポリシー（`AWS::Lambda::Permission`）の付与を厳密に制御します。

- **`AuthType: NONE`（`auth_type: :none`）**:
  - Webhook 等のパブリックエンドポイント向けに、`Action: 'lambda:InvokeFunctionUrl'`、`FunctionUrlAuthType: 'NONE'`、`Principal: '*'` を持つ `AWS::Lambda::Permission`（`#{FunctionLogicalId}UrlPermission`）を自動付与します。
- **`AuthType: AWS_IAM`（`auth_type: :aws_iam`）**:
  - IAM 認証を必須とする内部マイクロサービス向けに、`AWS::Lambda::Url` の `AuthType` を `'AWS_IAM'` に設定し、パブリックアクセスを許可する `AWS::Lambda::Permission` は一切生成しません。呼び出し元には SigV4 署名と適切な `lambda:InvokeFunctionUrl` IAM 権限が必要となります。

## Amazon MSK / Amazon MQ ブローカー連携の VPC・セキュリティグループおよび IAM 権限検証 (Broker VPC, Security Group & IAM Validation)

エンタープライズのメッセージブローカー（Amazon MSK / Kafka、Amazon MQ / ActiveMQ / RabbitMQ）をイベントソースとする場合、認証シークレット（Secrets Manager）および VPC 内ブローカー接続のセキュリティ要件をコンパイル時およびバリデーション時（`Veltrunode::Validation::Engine` / `Function#validate_invariants`）に検証します。

1. **Secrets Manager 認証シークレットの検証 (`VLT-IAM-003`)**:
   - Amazon MQ（`:mq`）ではブローカー認証が必須であるため、`secret`（または `SourceAccessConfigurations` 内の認証設定）が未指定の場合はエラー Diagnostic `VLT-IAM-003` を出力します。
   - `secret` にリテラル ARN が指定された場合、有効な Secrets Manager ARN（`arn:aws:secretsmanager:...`）であるかを検証し、不正な ARN の場合は `VLT-IAM-003` を出力します。
   - 付与される `secretsmanager:GetSecretValue` 権限は、指定されたシークレット ARN（またはパラメータ参照）のみに最小特権でスコープされます。
2. **VPC 内ブローカー接続用サブネット・セキュリティグループの整合性検証 (`VLT-DSL-VPC-001` / `VLT-REF-001`)**:
   - ブローカーイベントソースを持つ関数に `vpc_reference` が設定されている場合、またはイベントソース自体にネットワーク設定が指定されている場合、`subnet_ids` と `security_group_ids` の双方が揃っているかを検証します。片方のみの設定など不完全な VPC 構成はエラー Diagnostic `VLT-DSL-VPC-001` として検出されます。
   - シンボルで参照されたセキュリティグループヘルパーがアプリケーション内に定義されていない場合は、`VLT-REF-001` エラーを出力します。
3. **VPC ENI 管理権限とクラスタ/ブローカー読み取り権限の自動構成**:
   - Lambda が VPC 内の MSK クラスタまたは MQ ブローカーへポーリング接続するために必要な EC2 ネットワークインターフェース操作権限（`ec2:CreateNetworkInterface`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeVpcs`, `ec2:DeleteNetworkInterface`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`）および最小限のブローカー読み取り権限（`kafka-cluster:ReadData` 等 / `mq:DescribeBroker`）を自動付与します。ワイルドカードアクション（`kafka:*` や `ec2:*`）は一切使用しないため、本番ポリシーパックの `deny_wildcard_actions` にも完全準拠します。

## EFS 自動バックアップ用 AWS Backup IAM サービスロール (AWS Backup Service Role for EFS)

EFS マウント定義（`efs_mount` / `managed_access_point`）で `backup: true` または `backup: { schedule: ..., retention_days: ... }` が指定された場合、Lambda 実行ロールとは完全に分離された **AWS Backup 専用サービスロール**（`AWS::IAM::Role`、論理ID: `#{MountName}BackupRole`）が自動生成されます。

- **信頼ポリシー (`AssumeRolePolicyDocument`)**:
  - Principal として `backup.amazonaws.com` サービスのみに `sts:AssumeRole` を許可します。
- **アタッチされる AWS 管理ポリシー (`ManagedPolicyArns`)**:
  - `arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup`（バックアップ作成権限）
  - `arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores`（リストア実行権限）
- **リソース選択 (`AWS::Backup::BackupSelection`) のスコープ**:
  - バックアップ対象リソース（`Resources`）はワイルドカードを使用せず、該当する EFS ファイルシステム ARN（`Fn::GetAtt: [#{MountName}FileSystem, Arn]` または `arn:aws:elasticfilesystem:${AWS::Region}:${AWS::AccountId}:file-system/fs-xxxx`）のみに厳密に限定されます。

## 認証情報 (Credentials)

Veltrunode は、標準の AWS SDK 資格情報チェーン（Credential Chain）を使用します。ツール自体が認証情報を収集したり、プロキシしたりすることはありません。リソースの変更操作（`deploy` 等）を行う前に、呼び出し元の AWS アカウントおよびリージョンが正しいかを事前検証（`AccountRegionGuard`）します。

### デプロイ前ガード（AWS アカウントおよびリージョン整合性チェック）

誤ったAWS環境への意図しないデプロイを防ぐため、`veltrunode deploy` 実行直前に以下の検証を実施します。

1. **AWS 認証と呼び出し元アカウントの確認**:
   - `STS:GetCallerIdentity` を実行し、現在有効な AWS アカウント ID を取得します。
   - 認証失敗またはクライアント初期化不可の場合はエラー Diagnostic（`VLT-AWS-AUTH-001`）を出力し、デプロイを中止します。
2. **アカウント制約（`account` / `account_constraint`）との照合**:
   - `Veltrunodefile` にアカウント制約が明示されている場合、取得したアカウント ID と厳密に一致するかを照合します。不一致の場合はエラー Diagnostic（`VLT-AWS-ACCOUNT-001`）を出力し、デプロイを中止します。
   - アカウント制約が未設定の場合は、警告 Diagnostic（`VLT-AWS-ACCOUNT-002`）を出力して注意を促した上でデプロイを継続します。
3. **リージョン設定（`region`）との照合**:
   - 明示的に設定された AWS SDK / 環境変数（`AWS_REGION`, `AWS_DEFAULT_REGION`, `Aws.config[:region]`）と、`Veltrunodefile` に定義された `application.region` を照合します。
   - 不一致が検出された場合はエラー Diagnostic（`VLT-AWS-REGION-001`）を出力し、デプロイを中止します。
4. **終了コード**:
   - アカウント不一致、リージョン不一致、認証失敗等のエラーが検出された場合、CLI は終了コード `4`（`EXIT_AWS_AUTH_FAILED`）で安全に停止します。

## サプライチェーン (Supply Chain)

- 署名付きのリリースは、ロードマップ項目として定義されています。
- 依存する Gem 等のパッケージはロックされ、レビュー済みの自動化プロセスを通じてアップデートされます。
- リリースビルドは CI環境 で実行されます。
- **SBOM（ソフトウェア部品構成表）の自動生成**:
  - `veltrunode build` 実行時に、パッケージングされる Gem のソフトウェア部品構成表（SBOM）を自動生成し、ビルド成果物（デフォルト: `build/sbom.cdx.json`）として出力します。
  - 出力フォーマットは標準的な **CycloneDX 1.5**（または **SPDX 2.3**）JSON 形式をサポートします。
  - 構成表には、すべての Gem の完全な依存関係ツリー（Dependency Tree）、解決済みバージョン、パッケージURL（PURL: `pkg:gem/<name>@<version>`）、および解決されたライセンス情報が含まれます。
  - 生成された SBOM ファイルのパスは、ビルドマニフェスト（`manifest.json` の `sbom` / `sbom_path`）に記録され、監査やセキュリティスキャナー（Trivy, Grype, Snyk 等）との連携が可能です。
- セキュリティ報告に関しては、[SECURITY.md](../SECURITY.md) に規定されている手順に従います。
- 依存関係と GitHub Actions の更新は、[.github/dependabot.yml](../.github/dependabot.yml) を用いて自動化します。
