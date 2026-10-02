# テスト戦略 (Testing Strategy)

## ユニットテスト (Unit Tests)

以下のコンポーネントに対するテストを実施します。
- DSLビルダー、ドメインモデルの不変条件（Invariants）、リソースグラフの解決ロジック
- バリデータ、論理ID（Logical ID）の生成ロジック
- IAMケーパビリティの展開、cron式のパース、パッケージングルール
- エラー診断のフォーマット出力

## ゴールデンテスト (Golden Tests)

定義済みのテスト用 `Veltrunodefile` を使用し、レビュー済みの CloudFormation テンプレート（`template.yml`）およびマニフェストファイル（`manifest.json`）へのコンパイルをテストします。

### フィクスチャの配置 (`spec/fixtures/golden/`)
各テストパターンのディレクトリ配下に `Veltrunodefile`、期待される `template.yml`、期待される `manifest.json` を配置します。

- `minimal/`: 最小構成（関数1つ、スケジュール1つ）
- `with_layer/`: Layer付き構成（カスタムレイヤー、アーキテクチャ指定）
- `with_efs/`: EFSマウント付き構成（AccessPoint ARN、VPC設定、マウントパス）
- `multiple_resources/`: 複数関数・複数スケジュール構成（ログ保持、タグ、同時実行数、リトライ/DLQ）
- `with_iam_capabilities/`: IAMケーパビリティ付き構成（S3読み書き、SSMパラメータ、SNS発行）

### テストの実行とフィクスチャの更新

通常実行（差分検出）:
```bash
bundle exec rspec spec/golden_spec.rb
```

フィクスチャ更新:
```bash
UPDATE_GOLDEN=1 bundle exec rspec spec/golden_spec.rb
```

### Git差分レビューの要求
仕様変更やコンパイラの改修により出力結果に変更が発生した場合は、`UPDATE_GOLDEN=1` によりフィクスチャを意図的に更新した上で、必ず `git diff spec/fixtures/golden/` を実行し、生成される CloudFormation テンプレートおよびマニフェストの差分に対するセマンティックなレビューを行ってください。

## プロパティテスト (Property Tests)

`rantly`（`rantly/rspec_extensions`）を用いたプロパティベーステストにより、ランダムかつ多様な入力組み合わせに対して、以下の不変条件（Properties）が常に維持されることを検証します。

### 検証対象の主要プロパティ (`spec/property_spec.rb`)

1. **CloudFormation出力の決定性（Compilation Determinism）**
   - 同一のアプリケーションモデル・関数・スケジュール・IAMケーパビリティ設定に対して、複数回コンパイル（`to_yaml` および `compile`）を行っても、完全一致する同一の CloudFormation テンプレート YAML およびハッシュが出力されることを検証します。
2. **マップキーの安定ソート順序（Map Key Stable Sorting）**
   - 任意の深さを持つネストされた辞書構造に対して、`TemplateCompiler#deep_sort_keys` を通すことですべてのキーが文字列化され、アルファベット順に安定ソートされることを検証します。
3. **ファイルパスの正規化（Path Normalization）**
   - 冗長なスラッシュ（`//`）、カレントディレクトリ表現（`./`）、末尾スラッシュの除去が安全かつ冪等に行われること（`normalize(normalize(p)) == normalize(p)`）、および相対パス・絶対パスの種別が保持されることを検証します（`Veltrunode::PathNormalizer`）。
4. **論理ID生成の一意性と妥当性（Logical ID Uniqueness and Validity）**
   - 任意の名前文字列から生成される CloudFormation 論理ID（`LogicalId.for`）が英字開始の英数字（`\A[A-Z][a-zA-Z0-9]*\z`）に正規化されること、同一タイプ内での異なるシンボリック名同士が重複しないこと、および同一名称であっても異なるリソースタイプ間で一意のIDが割り振られることを検証します。
5. **参照解決の冪等性（Reference Resolution Idempotency）**
   - 複数関数、Layer、EFSマウント、スケジュール等が複雑に相互参照するアプリケーションモデルにおいて、リソースグラフ（`Veltrunode::Graph::ResourceGraph`）のトポロジカルソート順序や依存関係解決が状態変化を伴わず常に冪等・安定して評価されることを検証します。

### テストの実行

プロパティテスト単体の実行:
```bash
bundle exec rspec spec/property_spec.rb
```

テストスイート全体の一部としても実行されます:
```bash
bundle exec rspec
```

## 統合テスト (Integration Tests)

分離された専用の AWS テストアカウントを用いて、ビルド、CloudFormation スタックのデプロイ・削除、Lambda 関数実行、EventBridge スケジュール連携、EFS マウント・ファイル読み書きなどのエンドツーエンド（E2E）動作を検証します。

### テスト用 AWS アカウントの設定と事前準備

統合テストは AWS 上で実際のリソースを作成・削除するため、本番・開発環境から完全に分離された専用の **Sandbox / テスト用 AWS アカウント** で実行します。

#### 1. 必要な IAM 権限 (最小権限ポリシー)

テスト実行用プリンシパル（CI の OIDC ロールまたはテスト用 IAM ユーザー）には、以下の AWS サービスに対する権限が必要です。

- **AWS CloudFormation**: スタックの作成、更新、削除、変更セットの管理 (`cloudformation:*`)
- **AWS Lambda**: 関数の作成、更新、呼び出し、削除、レイヤーの公開 (`lambda:*`)
- **AWS IAM**: Lambda 実行ロールの作成、ポリシーのアタッチ、削除、PassRole (`iam:CreateRole`, `iam:DeleteRole`, `iam:PassRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`)
- **Amazon S3**: デプロイパッケージ・レイヤー zip のアップロードおよび削除 (`s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`)
- **Amazon EventBridge Scheduler**: スケジュールグループおよびスケジュールの作成、削除 (`scheduler:CreateSchedule`, `scheduler:DeleteSchedule`, `scheduler:GetSchedule`)
- **Amazon CloudWatch Logs**: ロググループの作成、ログイベントの読み取り・削除 (`logs:*`)
- **Amazon EC2 / Amazon EFS** (EFS テスト用): VPC 設定確認、ENI 作成、Access Point 参照 (`ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVpcs`, `elasticfilesystem:DescribeAccessPoints`, `elasticfilesystem:ClientMount`, `elasticfilesystem:ClientWrite`)

#### 2. 事前プロビジョニングが必要な共有リソース

- **テスト用 S3 バケット**: Lambda アーティファクトのアップロード用バケット（例: `veltrunode-test-artifacts-<account-id>-<region>`）
- **テスト用 VPC および EFS** (EFS 統合テスト用):
  - プライベートサブネット（Lambda 関数配置用）
  - EFS ファイルシステムおよびマウントターゲット
  - POSIX UID 1000 / GID 1000 に設定された EFS Access Point（例: `arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-...`）
  - Lambda 関数および EFS に適用するセキュリティグループ

#### 3. 設定する環境変数

統合テスト実行環境（ローカルまたは CI ランナー）に以下の環境変数を設定します。

| 環境変数名 | 必須/任意 | 説明 |
| :--- | :--- | :--- |
| `AWS_REGION` | 必須 | テストを実行する AWS リージョン (例: `ap-northeast-1`) |
| `AWS_ACCOUNT_ID` | 必須 | テスト用 AWS アカウント ID (12桁数値) |
| `AWS_ACCESS_KEY_ID` | 必須* | AWS アクセスキー (*OIDC 使用時は不要) |
| `AWS_SECRET_ACCESS_KEY` | 必須* | AWS シークレットアクセスキー (*OIDC 使用時は不要) |
| `VELTRUNODE_TEST_ARTIFACT_BUCKET` | 必須 | アーティファクト保存用の S3 バケット名 |
| `VELTRUNODE_TEST_EFS_ACCESS_POINT` | 任意 | EFS Access Point ARN (未設定時は EFS テストをスキップ) |
| `VELTRUNODE_TEST_SUBNET_IDS` | 任意 | EFS 用 VPC サブネット ID (カンマ区切り) |
| `VELTRUNODE_TEST_SECURITY_GROUP_IDS`| 任意 | EFS 用 セキュリティグループ ID (カンマ区切り) |

#### 4. GitHub Actions (CI) での OIDC 連携設定

GitHub Actions からテスト用 AWS アカウントへ安全にアクセスするために、OIDC（OpenID Connect）連携を使用します。

1. AWS IAM で GitHub OIDC ID プロバイダ (`token.actions.githubusercontent.com`) を作成。
2. リポジトリ (`Arcflect/veltrunode`) からの AssumeRoleWithWebIdentity を許可する IAM ロールを作成。
3. リポジトリの Secrets に `AWS_ROLE_TO_ASSUME`、`AWS_ACCOUNT_ID`、`VELTRUNODE_TEST_ARTIFACT_BUCKET` などを設定。

### 統合テストの実行方法

統合テストは通常のユニットテストから分離されており、`--tag integration` を明示した場合にのみ実行されます。

```bash
# すべての統合テストを実行
bundle exec rspec --tag integration

# 特定の統合テストのみを実行
bundle exec rspec spec/integration/stack_deploy_destroy_spec.rb --tag integration
```

### 自動クリーンアップの保証

統合テストフレームワークは、テスト終了時（成功・失敗を問わず）に以下を自動的にクリーンアップします。
- テスト実行ごとに一意のスタック名（`veltrunode-integ-<test-name>-<random-id>`）を使用し、名前衝突を防止。
- RSpec の `after` / `around` フックにより `Veltrunode::Destroy::Pipeline` を自動実行してスタックを完全削除。
- S3 アップローダーがテスト用にアップロードしたアーティファクトオブジェクトの削除。

## 互換性マトリクス (Compatibility Matrix)

サポート対象の Ruby バージョン、Bundler バージョン、CPUアーキテクチャ（`x86_64` / `arm64`）、サポート対象の Lambda ランタイム、LinuxおよびmacOSの開発者環境、ならびに CI ランナー環境を対象にテストを実行します。

## リリース基準 (Release Gates)

すべてのテスト、RuboCop、型チェック（導入している場合）、ドキュメントのコード例の実行、Gemのビルド、脆弱性スキャン、およびスモークデプロイテストがパスすることをリリース基準とします。
