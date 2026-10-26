# CloudFormation コンパイル (CloudFormation Compilation)

CloudFormationは本ツールのプライマリなデプロイ形式です。コンパイラは、独自の状態で表現された中間表現ではなく、標準のAWSリソースを出力します。

## 出力されるファイル群 (Outputs)

- `build/template.yml`: デプロイ可能なCloudFormationテンプレート。
- `build/manifest.json`: 正規化されたアプリケーションモデル、アーティファクトのハッシュ値、IAMの展開結果、およびコンパイラのバージョン情報。
- `build/artifacts/functions/*.zip`: 関数のデプロイパッケージ。
- `build/artifacts/layers/*.zip`: Layerのデプロイパッケージ。

## 決定性 (Determinism)

論理ID（Logical ID）は、ドキュメント化された安定した変換ルールを使用して、シンボリック名から生成されます。マップのキーはソートされ、コンテンツベースのハッシュ値出力からタイムスタンプは除外されます。また、ZIPファイルのエントリ内のタイムスタンプは可能な限り正規化されます。

## 論理ID (Logical ID) の生成ルール

CloudFormation の論理ID（Logical ID）は、`Veltrunode::Compiler::LogicalId` モジュールにより、シンボリック名から決定論的かつ安定したルールで生成されます。ルールが変更されると CloudFormation リソースの置換（Replacement）が発生するため、変換規則の安定性が保証されています。

### 変換規則

1. **PascalCase 変換**:
   - シンボリック名（Symbol または String）を単語区切り文字（`_`, `-`, `.`, `/`, スペース等）で分割し、各単語の先頭を大文字にして連結します（例: `:runtime_gems` → `RuntimeGems`）。
2. **リソース型ごとのサフィックス付与**:
   - リソースの種類に応じたサフィックスを付与します。
   - シンボリック名が既に該当サフィックスで終わっている場合、二重付与は行われません（例: `convert_function` → `ConvertFunction`）。
3. **決定性と一意性**:
   - 同一のシンボリック名およびリソース型からは常に同一の論理IDが生成されます。
   - 同一シンボリック名であってもリソース型（Function, Layer, Schedule 等）ごとに異なる論理IDが生成され、名前空間の衝突を防止します。

### リソース種別と変換例

| リソース種別 | シンボリック名例 | 生成される論理ID | 説明 |
| :--- | :--- | :--- | :--- |
| **Function** | `:convert` | `ConvertFunction` | Lambda 関数 (`AWS::Lambda::Function`) |
| **Layer** | `:runtime_gems` | `RuntimeGemsLayer` | Lambda Layer 論理名 |
| **LayerVersion** | `:runtime_gems` | `RuntimeGemsLayerVersion` | Lambda Layer バージョン (`AWS::Lambda::LayerVersion`) |
| **Schedule** | `:nightly` | `NightlySchedule` | EventBridge スケジュール (`AWS::Scheduler::Schedule`) |
| **Queue** | `:nightly_dlq` | `NightlyDlqQueue` | SQS キュー (`AWS::SQS::Queue`) |
| **LogGroup** | `:convert` | `ConvertFunctionLogGroup` | CloudWatch ロググループ (`AWS::Logs::LogGroup`) |
| **SubscriptionFilter** | `:convert` | `ConvertFunctionSubscriptionFilter` | CloudWatch Logs サブスクリプションフィルター (`AWS::Logs::SubscriptionFilter`) |
| **SubscriptionFilter (名前付き)** | `:convert` (`:opensearch`) | `ConvertFunctionOpensearchSubscriptionFilter` | 名前付きサブスクリプションフィルター (`AWS::Logs::SubscriptionFilter`) |
| **Lambda Permission** | `:convert` | `ConvertFunctionLogsPermission` | CloudWatch Logs からの Lambda 呼び出し権限 (`AWS::Lambda::Permission`) |
| **IAM Role (Logs Delivery)** | `:convert` | `ConvertFunctionLogsRole` | CloudWatch Logs から Kinesis/Firehose への配信ロール (`AWS::IAM::Role`) |
| **Alarm** | `:convert` (errors) | `ConvertFunctionErrorsAlarm` | CloudWatch アラーム (`AWS::CloudWatch::Alarm`) |
| **DLQ Alarm** | `:nightly_dlq` | `NightlyDlqQueueAlarm` | SQS DLQ メッセージ監視アラーム (`AWS::CloudWatch::Alarm`) |
| **IAM Role (Lambda)** | `:convert` | `ConvertFunctionRole` | Lambda 実行ロール (`AWS::IAM::Role`) |
| **IAM Role (Scheduler)** | `:nightly` | `NightlyScheduleRole` | Scheduler 呼び出しロール (`AWS::IAM::Role`) |
| **EventInvokeConfig** | `:convert` | `ConvertFunctionEventInvokeConfig` | Lambda 非同期呼び出し設定 (`AWS::Lambda::EventInvokeConfig`) |
| **Dashboard** | `:default` (`:operations`) | `Dashboard` (`OperationsDashboard`) | CloudWatch メトリクスダッシュボード (`AWS::CloudWatch::Dashboard`) |

## CloudWatch アラームのコンパイルと通知パラメータ (CloudWatch Alarms Compilation)

Lambda 関数で定義された `alarms` 設定は、`Veltrunode::Compiler::CloudFormation::AlarmCompiler` により `AWS::CloudWatch::Alarm` リソースとしてコンパイルされます。

- **論理ID**: `#{FunctionName}#{Metric}Alarm` 形式（例: `ConvertFunctionErrorsAlarm`, `ConvertFunctionDurationAlarm`, `ConvertFunctionThrottlesAlarm`）。
- **ターゲット関数紐付け**: `Dimensions` の `FunctionName` プロパティに `{ 'Ref' => FunctionLogicalId }` が設定され、Lambda 関数への参照依存が自動的に解決されます。
- **SNS 通知先パラメータ化**: アラーム通知先（`AlarmActions`）にシンボルや `ref(...)` でパラメータ名が指定された場合、CloudFormation テンプレートの `Parameters` に該当パラメータ（例: `AlertTopic: { Type: String, ... }`）が自動登録されます。リテラル ARN（`arn:aws:sns:...`）が指定された場合はそのまま展開されます。

## SQS デッドレターキュー (DLQ) メッセージ監視アラームのコンパイル (SQS DLQ Alarm Compilation)

Schedule の `dlq` 設定で `alarm: true` を指定した場合、Veltrunode が管理する SQS キューに対し、`Veltrunode::Compiler::CloudFormation::DlqAlarmCompiler` により `AWS::CloudWatch::Alarm` リソースが自動生成されます。

- **論理ID**: `#{QueueLogicalId}Alarm` 形式（例: `NightlyDlqQueueAlarm`）。
- **アラーム名のプレフィックス規約 (`AlarmName`)**:
  スタック名に基づいたプレフィックス規約 `{ 'Fn::Sub' => "${AWS::StackName}-#{LogicalId}" }`（例: `${AWS::StackName}-NightlyDlqQueueAlarm`）を統一適用し、CloudWatch コンソールや複数環境デプロイ時における一貫性と識別性を保証します。
- **即時発報メトリクス仕様**:
  - **MetricName**: `ApproximateNumberOfMessagesVisible`（可視メッセージ数）
  - **Namespace**: `AWS/SQS`
  - **Dimensions**: `QueueName` に `{ 'Fn::GetAtt' => [QueueLogicalId, 'QueueName'] }`
  - **Threshold**: `0`（`ComparisonOperator`: `GreaterThanThreshold`）
  - **即時検知**: `Period: 60`（1分）、`EvaluationPeriods: 1`、`Statistic: Maximum`、`TreatMissingData: notBreaching` により、DLQ にメッセージが到着した直後（最短1分）に即時発報されます。
- **SNS 通知先パラメータ化**:
  `topic`（例: `topic: ref(:alert_topic)`）が指定された場合、CloudFormation テンプレートの `Parameters` に該当パラメータが自動登録され、`AlarmActions` に通知先が設定されます。

## CloudWatch Logs サブスクリプションフィルターのコンパイルとクロスサービス権限 (Subscription Filter Compilation)

Lambda 関数の `logs` 設定で定義された `subscription_filter` は、`Veltrunode::Compiler::CloudFormation::SubscriptionFilterCompiler` により `AWS::Logs::SubscriptionFilter` リソースおよび必要な実行権限リソースとしてコンパイルされます。

- **論理ID**:
  - デフォルト: `#{FunctionName}SubscriptionFilter`
  - 名前付き: `#{FunctionName}#{FilterName}SubscriptionFilter`
- **対象ロググループ紐付け**: `LogGroupName` に `{ 'Ref' => FunctionLogGroupLogicalId }` が設定されます。
- **クロスサービス実行権限の自動生成**:
  - **Lambda 宛先**:
    CloudWatch Logs が宛先 Lambda 関数を呼び出すための `AWS::Lambda::Permission`（Action: `lambda:InvokeFunction`、Principal: `logs.${AWS::Region}.amazonaws.com`、SourceArn: LogGroup の ARN）が自動生成されます。また、権限生成完了前にフィルターが作られることによるエラーを防ぐため、`SubscriptionFilter` に `DependsOn` が設定されます。
  - **Kinesis / Firehose 宛先**:
    宛先 ARN から自動判定（または `destination_type` 指定）され、明示的な `role_arn` が指定されていない場合は、CloudWatch Logs がストリームにレコードを書き込むための `AWS::IAM::Role`（Service: `logs.${AWS::Region}.amazonaws.com`、アクション: `kinesis:PutRecord*` または `firehose:PutRecord*`）が自動生成されます。
- **宛先・ロール ARN のパラメータ化**:
  宛先や `role_arn` にパラメータ名や Ref が指定された場合、CloudFormation テンプレートの `Parameters` に該当パラメータが自動登録されます。

## X-Ray Active Tracing および ADOT のコンパイル (Tracing Configuration)

Lambda 関数で `tracing: :active` または `tracing: :pass_through`（または `defaults` ブロックでの指定）を設定した場合、`Veltrunode::Compiler::CloudFormation::FunctionCompiler` および `RoleCompiler` により以下のリソース定義が自動構成されます。

- **TracingConfig の生成**:
  `AWS::Lambda::Function` の `Properties.TracingConfig` に `{ 'Mode' => 'Active' }` または `{ 'Mode' => 'PassThrough' }` が設定されます。
- **X-Ray 書込権限の自動付与**:
  Lambda 実行ロール（`AWS::IAM::Role`）の `Properties.ManagedPolicyArns` に、AWS 管理ポリシー `arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess` が自動的に追加されます。
- **AWS Distro for OpenTelemetry (ADOT) レイヤー自動アタッチ**:
  `tracing: :adot` を指定した場合、Active Tracing の有効化に加えて、対象関数のランタイムおよびアーキテクチャ（`x86_64` / `arm64`）に対応した公式 ADOT Lambda レイヤー（`aws-otel-...`）が `Properties.Layers` に自動的にアタッチされます。また、ゼロコード計装に必要な環境変数 `AWS_LAMBDA_EXEC_WRAPPER: '/opt/otel-instrument'` も自動設定されます（カスタム ADOT レイヤー ARN の指定も可能です）。

## Lambda Insights 拡張モニタリングのコンパイル (Lambda Insights Configuration)

Lambda 関数で `insights: true`（または `defaults` ブロックでの指定）を設定した場合、`Veltrunode::Compiler::CloudFormation::FunctionCompiler` および `RoleCompiler` により詳細システムメトリクス（CPU、メモリ、ネットワーク等）を収集するための拡張機能と権限が自動構成されます。

- **Lambda Insights 拡張レイヤーの自動アタッチ**:
  関数のアーキテクチャ（`x86_64` または `arm64`）に応じた公式 Lambda Insights 拡張レイヤーが `Properties.Layers` に自動追加されます。
  - `x86_64`: `{ 'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:580247275435:layer:LambdaInsightsExtension:53' }`
  - `arm64`: `{ 'Fn::Sub' => 'arn:aws:lambda:${AWS::Region}:580247275435:layer:LambdaInsightsExtension-Arm64:31' }`
  - リージョン自動解決: 中国リージョン（`cn-*`）や AWS GovCloud（`us-gov-*`）環境では、各パーティションおよび対応する専用 AWS アカウント ID（中国: `018784642996`、GovCloud: `519776269227`）が自動解決されます。
- **バージョンおよびカスタムレイヤー指定**:
  - `insights version: 45`: 特定のレイヤーバージョンを指定可能。
  - `insights layer_arn: "arn:..."`: カスタムの Lambda Insights レイヤー ARN を直接指定可能。
- **個別関数のオプトアウト**:
  `defaults` で `insights true` を有効化している場合でも、個別関数で `insights false` を設定することで Lambda Insights をオプトアウトできます。
- **IAM 実行権限の自動付与**:
  Lambda 実行ロール（`AWS::IAM::Role`）の `Properties.ManagedPolicyArns` に、AWS 管理ポリシー `arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy` が自動的に追加されます。

## Lambda 非同期呼び出し設定のコンパイル (EventInvokeConfig Compilation)

Lambda 関数で `async_invoke`（または `defaults` ブロックでの指定）を設定した場合、`Veltrunode::Compiler::CloudFormation::EventInvokeConfigCompiler` および `RoleCompiler` により `AWS::Lambda::EventInvokeConfig` リソースおよび必要な実行権限が自動構成されます。

- **論理ID**: `#{FunctionName}EventInvokeConfig`（例: `ConvertFunctionEventInvokeConfig`）。
- **リソースプロパティ (`Properties`)**:
  - `FunctionName`: `{ 'Ref' => FunctionLogicalId }`
  - `Qualifier`: デフォルトは `'$LATEST'`
  - `MaximumRetryAttempts`: 指定された最大リトライ回数（0〜2）
  - `MaximumEventAgeInSeconds`: 指定されたイベント最大有効期限（60〜21,600秒）
  - `DestinationConfig`: `OnSuccess` および `OnFailure` 送信先設定
- **送信先連携と IAM 実行権限の自動付与**:
  送信先（`on_success` / `on_failure`）が設定された場合、対象サービスに応じた IAM 権限が Lambda 実行ロール（`AWS::IAM::Role`）へ自動的に付与されます。
  - **SQS**: `sqs:SendMessage`
  - **SNS**: `sns:Publish`
  - **EventBridge**: `events:PutEvents`
  - **Lambda**: `lambda:InvokeFunction`
- **送信先パラメータ化**:
  送信先にシンボル名や Ref が指定された場合、CloudFormation テンプレートの `Parameters`（例: `FailedEventsQueueArn: { Type: String, ... }`）に自動登録されます。リテラル ARN（`arn:aws:...`）が指定された場合はそのまま展開されます。

## CloudWatch メトリクスダッシュボードのコンパイルと URL 出力 (CloudWatch Dashboard Compilation & Output)

Application レベルで `dashboard` を設定した場合、`Veltrunode::Compiler::CloudFormation::DashboardCompiler` により `AWS::CloudWatch::Dashboard` リソースが自動生成されます。

- **論理ID**: デフォルトは `Dashboard`、名前付きの場合は `#{Name}Dashboard`。
- **リソース名 (`DashboardName`)**: `{ 'Fn::Sub' => "${AWS::StackName}-Dashboard" }` または `{ 'Fn::Sub' => "${AWS::StackName}-#{LogicalId}" }`。
- **ウィジェットレイアウト (`DashboardBody`)**:
  幅 24 のグリッドシステムに基づき、各ウィジェット（幅 12, 高さ 6）が 2x2 で配置されます。
  - `Invocations` (呼び出し数、Stat: `Sum`)
  - `Errors` (エラー数、Stat: `Sum`)
  - `Duration` (所要時間、Stat: `Average`)
  - `ConcurrentExecutions` (同時実行数、Stat: `Maximum`)
  各ウィジェットの `metrics` プロパティには、アプリケーションで定義された全 Lambda 関数（`${FunctionName}`）が自動的に登録され、同一グラフ上で比較・監視できます。
- **デプロイ出力 (`Outputs.DashboardUrl`)**:
  CloudFormation の `Outputs` に論理名 `DashboardUrl` として CloudWatch コンソールの直接リンクが生成されます。
  - 値: `https://${AWS::Region}.console.aws.amazon.com/cloudwatch/home?region=${AWS::Region}#dashboards/dashboard/${Dashboard}`
- **CLI デプロイ出力**:
  `veltrunode deploy` の実行完了時に、コンソールへ `Dashboard URL: https://...` を表示します（JSON 出力時は `data.dashboard_url` に含まれます）。

## 変更セット (Change Sets)

`plan` コマンドはCloudFormationの変更セット（Change Set）を使用するため、ユーザーは実行前に変更内容を確認できます。リソースの置換（Replacement）や削除（Deletion）の影響は強調して表示されます。なお、計画（plan）がすべての実行時リスクを排除できると主張することはありません。

## 既存のインフラストラクチャ (Existing Infrastructure)

参照先には、リテラルARN、CloudFormationパラメータ、スタック出力（Export）、またはステージごとの値を指定できます。ユーザーが明確に本ツール側にリソース管理を要求しない限り、既存のEFS、VPC、サブネット、セキュリティグループ、キュー、およびS3バケットをCloudFormationスタック内にインポート（管理対象化）すべきではありません。

## S3 アーティファクトのアップロードと参照更新 (S3 Artifact Upload & Reference Updating)

Lambda 関数のデプロイパッケージおよび Layer バージョンのデプロイパッケージは、`Veltrunode::AWS::S3Uploader` を通じて指定された S3 バケットへアップロードされます。

### S3 キー命名規則
アーティファクトの S3 キーは、決定論的なコンテンツハッシュを含めることで重複アップロードを防止し、バージョニングされた一貫性を保ちます。

形式:
`veltrunode/<app>/<stage>/<hash>/<name>.zip`

- `<app>`: アプリケーション名（`application.name`）
- `<stage>`: デプロイステージ（例: `production`, `dev`）
- `<hash>`: ビルド成果物のコンテンツハッシュ（SHA-256）
- `<name>`: 関数名（`function.logical_name`）または Layer 名（`layer.name`）

### 重複アップロードのスキップ (Deduplication)
アップロード前に `head_object` API を実行し、同一コンテンツハッシュのオブジェクトが S3 上に既に存在する場合は実際のファイル転送をスキップします。これにより、変更のないパッケージの不要な転送コストやレイテンシを排除します。

### テンプレート参照の更新
アーティファクトがアップロードされると、生成された CloudFormation テンプレート（`build/template.yml`）内のリソース定義が自動的に更新されます。

- **Lambda 関数 (`AWS::Lambda::Function`)**:
  `Properties.Code.S3Bucket` および `Properties.Code.S3Key` がアップロード先 S3 バケットおよび S3 キーで更新されます。
- **Lambda Layer (`AWS::Lambda::LayerVersion`)**:
  `Properties.Content.S3Bucket` および `Properties.Content.S3Key` がアップロード先 S3 バケットおよび S3 キーで更新されます。

### CLI での利用
ビルド時に `--bucket` オプションを指定することで、ビルド直後にアーティファクトのアップロードおよびテンプレート更新を自動実行できます。

```bash
veltrunode build --bucket my-deployment-bucket
```

また、`Veltrunodefile` の `aws` 設定ブロックで `artifact_bucket` を指定することも可能です。
```ruby
Veltrunode.application "my-app" do
  aws region: "ap-northeast-1", artifact_bucket: "my-deployment-bucket"
end
```
