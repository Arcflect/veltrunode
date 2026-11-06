# Ruby DSL 仕様 (Ruby DSL Specification)

## 設定ファイル

デフォルトのファイル名: `Veltrunodefile`。`--file` オプションを使用してカスタムファイルを指定することもできます。

## 評価ルール

- DSL評価は制限されたコンテキストで行われ、決定論的（再現可能）であることが求められます。
- DSL評価の実行中にデプロイ処理が発生することはありません。
- ユーザーコード内で環境変数を明示的に読み取ることができます。秘密情報（シークレット）としてマークされた解決済みの値は、ログに出力されません。
- 定義されていない不明なメソッドが呼び出された場合は、即座にエラーとなります。

## アプリケーション設定例

```ruby
Veltrunode.application "document-converter" do
  aws region: "ap-northeast-1", account: "123456789012"
  runtime ruby: "3.4", architecture: :arm64

  defaults do
    logs retention_days: 30
    tags system: "document-converter", managed_by: "veltrunode"
  end

  layer :runtime_gems do
    bundle lockfile: "Gemfile.lock", without: %i[development test]
    include_gems %w[aws-sdk-s3 nokogiri]
    build_on :amazon_linux_2023
    retain latest: 5
  end

  efs_mount :workspace do
    existing_access_point arn: env("EFS_ACCESS_POINT_ARN")
    local_path "/mnt/workspace"
    expect_posix uid: 1000, gid: 1000
  end

  function :convert do
    handler "functions/convert.handler"
    memory 4096
    timeout 900
    ephemeral_storage 4096
    attach_layer :runtime_gems
    mount :workspace
    permit do
      read_from_s3 bucket: ref(:input_bucket)
      write_to_s3 bucket: ref(:output_bucket)
    end
    alarms do
      topic ref(:alert_topic)
      errors threshold: 1, period: 60
      duration threshold: 5000, statistic: "Average"
      throttles threshold: 2
    end
  end

  schedule :nightly do
    target :convert
    cron "0 1 * * ? *", timezone: "Asia/Tokyo"
    input source: "nightly"
    retry maximum_attempts: 2, maximum_event_age: 7200
    dead_letter_queue arn: env("SCHEDULER_DLQ_ARN")
  end
end
```

## CloudWatch メトリクスアラーム (CloudWatch Alarms)

`function` 内または `defaults` ブロックで `alarms` を定義することで、Lambda 関数のエラー、エラー率、レイテンシ（実行時間）、スロットルを監視する `AWS::CloudWatch::Alarm` リソースを自動生成できます。

### 推奨アラームプリセット (`alarms: :recommended`)

ベストプラクティスに基づいた標準的なアラームセットを一括で設定する `:recommended` プリセットを提供しています。

```ruby
Veltrunode.application "document-converter" do
  defaults do
    # アプリケーション全体の関数に推奨アラームプリセットを一括適用
    alarms :recommended, topic: ref(:alert_topic)
  end

  function :convert do
    handler "converter.handler"
    timeout 10
    # 自動展開されるアラーム:
    # 1. error_rate > 1% (CloudWatch Metric Math: 100 * (Errors / Invocations))
    # 2. throttles >= 1回
    # 3. duration > 8000ms (timeout 10秒の 80%)
  end

  function :heavy_batch do
    handler "batch.handler"
    timeout 30

    # プリセットの閾値を個別オーバーライド
    alarms :recommended do
      error_rate 5   # エラー率閾値を 5% に変更
      duration 20000 # Duration 閾値を 20,000ms に変更
    end
  end

  function :internal_job do
    handler "job.handler"
    # アラーム設定のオプトアウト（無効化）
    alarms false
  end
end
```

#### 推奨プリセットで自動展開されるアラーム一覧

| メトリクス | デフォルト閾値 | 比較演算子 | 説明 |
| :--- | :--- | :--- | :--- |
| **`error_rate`** | `> 1%` | `GreaterThanThreshold` | CloudWatch Metric Math (`100 * (e1 / MAX([i1, 1]))`) によりエラー率を算出 |
| **`throttles`** | `>= 1` | `GreaterThanOrEqualToThreshold` | 同時実行数制限やバーストクォータ超過によるスロットル発生を即時検知 |
| **`duration`** | `> timeout * 80%` | `GreaterThanThreshold` | 関数のタイムアウト秒数（ミリ秒換算）の 80% を超過した場合に検知 |

### アラーム個別定義とカスタマイズ

- **`topic`**: アラーム通知先 SNS トピック ARN（リテラル ARN または `ref(:param_or_resource)`）。
- **`error_rate`**: エラー率アラーム（Metric Math による数式監視、閾値は 0〜100%）。
- **`errors`**: エラー数アラーム（デフォルト統計: `Sum`）。
- **`duration`**: 実行時間アラーム（デフォルト統計: `Average`、閾値はミリ秒）。
- **`throttles`**: スロットル数アラーム（デフォルト統計: `Sum`）。
- **パラメータ指定**: `threshold`, `period`（秒数、10の倍数）, `evaluation_periods`, `statistic`, `comparison_operator`, `treat_missing_data` をカスタマイズ可能。

## Lambda Insights 拡張モニタリング (Lambda Insights)

`function` 内または `defaults` ブロックで `insights: true` を設定することで、CloudWatch Lambda Insights による詳細システムメトリクス（CPU、メモリ、ネットワークトラフィック等）の収集を有効化できます。

```ruby
Veltrunode.application "document-converter" do
  defaults do
    insights true # アプリケーション全体で Lambda Insights を有効化
  end

  function :convert do
    handler "converter.handler"
    runtime "nodejs20.x"
    architecture :arm64
  end

  function :lightweight do
    handler "simple.handler"
    runtime "python3.12"
    insights false # 個別関数でのオプトアウト
  end
end
```

- **`insights true` / `insights: true`**: 有効化（関数のアーキテクチャに応じた拡張レイヤーを自動アタッチし、必要な IAM 実行権限を自動付与）。
- **`insights version: 53`**: 拡張レイヤーの特定バージョンを指定。
- **`insights layer_arn: "arn:..."`**: カスタム拡張レイヤー ARN を指定。

## Lambda 非同期呼び出し設定 (Async Invoke Configuration)

非同期実行時の意図しない過剰リトライや古いイベントの滞留を防ぐため、`function` 内または `defaults` ブロックで `async_invoke` を指定し、リトライ回数やイベント有効期限、成功/失敗時の送信先（On-Success / On-Failure）を設定できます。

```ruby
Veltrunode.application "async-app" do
  defaults do
    # アプリケーション共通の非同期呼び出し制御
    async_invoke max_retries: 2, max_age_seconds: 3600
  end

  function :worker do
    handler "worker.handler"
    runtime "nodejs20.x"
  end

  function :critical_job do
    handler "critical.handler"
    runtime "ruby3.3"
    # 送信先連携（SQS / SNS / EventBridge / Lambda）および個別リトライ制御
    async_invoke max_retries: 1,
                 on_success: "arn:aws:sqs:ap-northeast-1:123456789012:success-queue",
                 on_failure: "arn:aws:sns:ap-northeast-1:123456789012:failure-topic"
  end

  function :sync_only do
    handler "sync.handler"
    runtime "python3.12"
    async_invoke false # 個別関数でのオプトアウト
  end
end
```

- **`max_retries` / `maximum_retry_attempts`**: 最大リトライ回数（0〜2）。
- **`max_age` / `max_age_seconds` / `maximum_event_age_in_seconds`**: イベント最大有効期限（秒数、60〜21,600秒）。
- **`on_success` / `on_failure`**: 成功時または失敗時のイベント送信先 ARN、参照（SQS キュー、SNS トピック、EventBridge イベントバス、Lambda 関数）。
- **個別関数のオプトアウト**: `defaults` で有効化している場合でも、`async_invoke false` を指定することで非同期呼び出し設定を無効化できます。

## SQS イベントソースマッピング (SQS Event Source Mapping)

SQS キューをトリガーとするワーカー関数において、バッチサイズやバッチ集約ウィンドウ、部分失敗（ReportBatchItemFailures）を制御する `AWS::Lambda::EventSourceMapping` を宣言的に定義できます。

```ruby
Veltrunode.application "sqs-worker-app" do
  defaults do
    # アプリケーション全体の標準バッチ設定（必要に応じて）
    event_source sqs: :orders,
                 batch_size: 10,
                 maximum_batching_window_in_seconds: 20,
                 report_batch_item_failures: true
  end

  # 1. ハッシュ形式の指定
  function :order_processor do
    handler "processor.handler"
    runtime "ruby3.3"
    event_source sqs: :orders,
                 batch_size: 50,
                 maximum_batching_window_in_seconds: 10,
                 report_batch_item_failures: true
  end

  # 2. 外部キュー ARN の指定とブロック構文
  function :external_worker do
    handler "external.handler"
    runtime "ruby3.3"
    event_source :sqs do
      queue "arn:aws:sqs:ap-northeast-1:123456789012:external-queue"
      batch_size 100
      batch_window 5
      report_batch_item_failures true
    end
  end

  # 3. defaults からのオプトアウト
  function :api_handler do
    handler "api.handler"
    runtime "ruby3.3"
    event_source false
  end
end
```

### パラメータ仕様

- **`queue` / `sqs`**: 対象の SQS キュー。スタック内シンボル（例: `:orders`）または完全な SQS キュー ARN（`arn:aws:sqs:...`）を指定します。
- **`batch_size`**: 1 回の呼び出しで関数に渡される最大メッセージ数（1〜10,000、デフォルト: AWS 標準の 10）。
- **`maximum_batching_window_in_seconds` / `batch_window`**: メッセージをバッチに蓄積するために待機する最大秒数（0〜300秒）。
- **`report_batch_item_failures`**: 部分バッチ応答を有効化（`true` の場合、`FunctionResponseTypes: ['ReportBatchItemFailures']` が設定され、バッチ内の一部の失敗メッセージのみを安全にリトライ可能）。
- **`enabled`**: イベントソースマッピングの有効/無効フラグ（デフォルト: `true`）。
- **自動 IAM 権限付与**: `event_source` が定義された関数には、SQS キューからの読込・削除に必要な権限（`sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`）が Lambda 実行ロールに自動付与されます。

## SNS トピックサブスクリプション (SNS Topic Subscription)

イベント駆動アーキテクチャにおいて SNS トピックからのプッシュ通知を Lambda で受信する場合、`event_source sns: ...` でトピック ARN または参照（`ref(:topic)` / シンボル）を指定することで、`AWS::SNS::Subscription` および呼び出し許可 `AWS::Lambda::Permission` を宣言的に定義できます。また、フィルタポリシー（`FilterPolicy`）によるイベントフィルタリングもサポートしています。

```ruby
Veltrunode.application "sns-subscriber-app" do
  # 1. ハッシュ形式の指定（トピック参照 + フィルタポリシー）
  function :order_notifier do
    handler "notifier.handler"
    runtime "ruby3.3"
    event_source sns: ref(:order_events_topic),
                 filter_policy: {
                   event_type: ["order_created", "order_cancelled"],
                   amount: [{ numeric: [">=", 1000] }]
                 }
  end

  # 2. 外部トピック ARN の指定とブロック構文
  function :audit_logger do
    handler "audit.handler"
    runtime "ruby3.3"
    event_source :sns do
      topic "arn:aws:sns:ap-northeast-1:123456789012:security-alerts"
      filter_policy severity: ["high", "critical"]
      filter_policy_scope :message_attributes
    end
  end
end
```

### パラメータ仕様

- **`topic` / `topic_arn` / `sns`**: 対象の SNS トピック。完全な SNS トピック ARN（`arn:aws:sns:...`）または `ref(:topic_name)` / シンボル（CloudFormation パラメータ参照）を指定します。
- **`filter_policy`**: サブスクリプションに適用するフィルタポリシー（`FilterPolicy`）を Hash で指定します。条件に合致するメッセージのみが Lambda 関数へ配信されます。
- **`filter_policy_scope`**: フィルタポリシーの評価対象スコープ（`MessageAttributes` または `MessageBody`、省略時は AWS デフォルトの `MessageAttributes`）。
- **自動呼び出し権限付与**: SNS サービス（`sns.amazonaws.com`）から対象 Lambda 関数を呼び出すための `AWS::Lambda::Permission`（`lambda:InvokeFunction`、`SourceArn`: 対象トピック ARN）が自動的に付与されます。

## S3 バケットイベント通知と Lambda トリガー (S3 Bucket Event Notification)

S3 バケットへのオブジェクト作成（`s3:ObjectCreated:*`）や削除（`s3:ObjectRemoved:*`）等を契機としたファイル処理パイプラインを構築する場合、`event_source s3: { bucket: ..., events: [...], filter: ... }` でバケット、イベント種別、およびキーのプレフィックス/サフィックスフィルタを指定して Lambda トリガーを自動設定できます。

```ruby
Veltrunode.application "s3-pipeline-app" do
  # 1. マネージド S3 バケットの指定（AWS::S3::Bucket 通知設定 + AWS::Lambda::Permission を自動生成）
  function :convert, event_source: {
    s3: {
      bucket: :uploads,
      events: ["s3:ObjectCreated:*"],
      filter: { prefix: "incoming/", suffix: ".jpg" }
    }
  } do
    handler "convert.handler"
    runtime "ruby3.3"
  end

  # 2. ブロック構文での指定
  function :video_transcoder do
    handler "transcode.handler"
    runtime "ruby3.3"
    event_source :s3 do
      bucket :uploads
      events "s3:ObjectCreated:Put", "s3:ObjectCreated:CompleteMultipartUpload"
      filter prefix: "videos/", suffix: ".mp4"
    end
  end

  # 3. 既存バケット（ref パラメータまたは ARN）の指定（AWS::Lambda::Permission のみ生成）
  function :archive do
    handler "archive.handler"
    runtime "ruby3.3"
    event_source s3: {
      bucket: ref(:external_archive_bucket),
      events: ["s3:ObjectCreated:*"]
    }
  end
end
```

### パラメータ仕様

- **`bucket` / `s3`**: 対象の S3 バケット。
  - スタック内シンボル（例: `:uploads`）またはバケット識別名を指定した場合は、Veltrunode 管理の `AWS::S3::Bucket`（通知設定 `NotificationConfiguration.LambdaConfigurations` 付き）および `AWS::Lambda::Permission` を生成します。
  - `ref(:bucket_name)` または完全な S3 バケット ARN（`arn:aws:s3:::...`）を指定した場合は、既存インフラストラクチャ保護ルールに従い `AWS::S3::Bucket` は生成せず、S3 からの呼び出しを許可する `AWS::Lambda::Permission` のみを生成します。
- **`events` / `event`**: トリガー対象の S3 イベント種別（文字列または配列、デフォルト: `['s3:ObjectCreated:*']`）。`s3:` プレフィックスで始まる有効なイベント名を指定します。
- **`filter` (`prefix` / `suffix`)**: S3 オブジェクトキーのフィルタ条件（`prefix`: プレフィックス、`suffix`: サフィックス）。`NotificationConfiguration.LambdaConfigurations[].Filter.S3Key.Rules` に展開されます。

## DynamoDB Streams イベントソースマッピング (DynamoDB Streams Event Source Mapping)

DynamoDB テーブルの変更ストリーム（DynamoDB Streams）を購読してリアクティブなデータ更新や集計を行う場合、`event_source dynamodb_stream: ...` でストリーム ARN または参照（`ref(:stream_arn)`）と読み取り開始位置（`starting_position: :latest / :trim_horizon`）を指定することで、`AWS::Lambda::EventSourceMapping` およびストリーム読み取りに必要な IAM 権限を自動構成できます。

```ruby
Veltrunode.application "ddb-stream-app" do
  # 1. ハッシュ形式の指定（ストリーム ARN + starting_position）
  function :order_projector do
    handler "projector.handler"
    runtime "ruby3.3"
    event_source dynamodb_stream: "arn:aws:dynamodb:ap-northeast-1:123456789012:table/Orders/stream/2026-01-01T00:00:00.000",
                 starting_position: :trim_horizon,
                 batch_size: 100,
                 maximum_batching_window_in_seconds: 5,
                 report_batch_item_failures: true
  end

  # 2. パラメータ参照とブロック構文での指定
  function :audit_aggregator do
    handler "aggregator.handler"
    runtime "ruby3.3"
    event_source :dynamodb_stream do
      stream ref(:audit_stream_arn)
      starting_position :latest
      batch_size 50
      batch_window 10
    end
  end
end
```

### パラメータ仕様

- **`stream` / `stream_arn` / `dynamodb_stream`**: 対象の DynamoDB Streams ARN（`arn:aws:dynamodb:...:table/<TableName>/stream/...`）または `ref(:stream_arn)` / シンボル（CloudFormation パラメータ参照）。
- **`starting_position`**: ストリームの読み取り開始位置。`:latest`（`'LATEST'`: 最新の変更レコードから読み取り、省略時のデフォルト）または `:trim_horizon`（`'TRIM_HORIZON'`: 利用可能な最古のレコードから読み取り）を指定します。
- **`batch_size`**: 1 回の呼び出しで関数に渡される最大レコード数（1〜10,000）。
- **`maximum_batching_window_in_seconds` / `batch_window`**: レコードをバッチに蓄積するために待機する最大秒数（0〜300秒）。
- **`report_batch_item_failures`**: 部分バッチ応答を有効化（`true` の場合、`FunctionResponseTypes: ['ReportBatchItemFailures']` を設定）。
- **`enabled`**: イベントソースマッピングの有効/無効フラグ（デフォルト: `true`）。
- **自動 IAM 権限付与**: `dynamodb_stream` が定義された関数には、ストリーム読み取りに必要な IAM 権限（`dynamodb:GetRecords`, `dynamodb:GetShardIterator`, `dynamodb:DescribeStream`, `dynamodb:ListStreams`）が Lambda 実行ロールに自動付与されます。

## EventBridge カスタムイベントバストリガーとルールパターン (EventBridge Rule & Custom Event Bus)

定期実行の Scheduler だけでなく、カスタムイベントバス（またはデフォルトイベントバス）に送信されるドメインイベントを受信して起動する関数を構築する場合、`rule: { bus: ..., pattern: { source: [...], 'detail-type': [...] } }` で EventBridge ルールとイベントパターン（JSON マッチング）を記述し、`AWS::Events::Rule` および `AWS::Lambda::Permission` を自動生成できます。

```ruby
Veltrunode.application "eventbridge-app" do
  # 1. function キーワード引数での指定
  function :order_handler, rule: {
    bus: "custom-orders-bus",
    pattern: {
      source: ["myapp.orders"],
      "detail-type": ["OrderCreated", "OrderCompleted"]
    }
  } do
    handler "orders.handler"
    runtime "ruby3.3"
  end

  # 2. function ブロック内での rule 指定（state: :disabled サポート）
  function :billing_handler do
    handler "billing.handler"
    runtime "ruby3.3"
    rule bus: ref(:domain_bus),
         pattern: {
           source: ["myapp.billing"],
           "detail-type": ["InvoiceIssued"]
         },
         state: :disabled
  end
end
```

### パラメータ仕様

- **`bus` / `event_bus` / `event_bus_name`**: 対象の EventBridge イベントバス名、ARN、または `ref(:bus_param)`（CloudFormation パラメータ参照）。省略時は `default` イベントバスが使用されます。
- **`pattern` / `event_pattern`**: EventBridge のイベントパターン（`source`, `'detail-type'`, `detail` 等）を Hash で指定します。
- **`state`**: ルールの有効/無効フラグ。`:enabled`（`'ENABLED'`、デフォルト）または `:disabled`（`'DISABLED'`）を指定します。
- **自動呼び出し権限付与**: EventBridge（`events.amazonaws.com`）から対象 Lambda 関数を呼び出すための `AWS::Lambda::Permission`（`lambda:InvokeFunction`、`SourceArn`: ルールの ARN）が自動的に付与されます。

## API Gateway HTTP API (v2) とルート・CORS 定義 (HTTP API v2 & Routes)

サーバーレス API を迅速かつ安価に構築する場合、Application レベルで `http_api` ブロックを宣言することで、HTTP メソッドとパスのルート定義および CORS 設定から `AWS::ApiGatewayV2::Api`、`Stage`、`Integration`、`Route`、および `AWS::Lambda::Permission` を自動生成できます。

```ruby
Veltrunode.application "users-http-api" do
  http_api do
    cors allow_origins: ["https://example.com"],
         allow_methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
         allow_headers: ["Content-Type", "Authorization"],
         max_age: 86400,
         allow_credentials: true

    get "/users", to: :list_users
    post "/users", to: :create_user
    get "/users/{id}", to: :get_user
    put "/users/{id}", to: :update_user
    delete "/users/{id}", to: :delete_user
  end

  function :list_users do
    handler "users.list"
    runtime "ruby3.3"
  end

  function :create_user do
    handler "users.create"
    runtime "ruby3.3"
  end
end
```

### パラメータ仕様

- **ルート定義メソッド (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `any`, `route`)**:
  - 第1引数にルートパス（例: `'/users'`, `'/users/{id}'`）、`to:`（エイリアス: `target:`, `function:`）にターゲット Lambda 関数名を指定します。
- **`cors`**:
  - `cors true`: 全オリジン・全メソッド・全ヘッダー（`'*'`）を許可する簡易指定。
  - ハッシュまたはブロック形式で `allow_origins`（`origins`）、`allow_methods`（`methods`）、`allow_headers`（`headers`）、`expose_headers`、`max_age`、`allow_credentials`（`credentials`）を指定可能。
- **`stage_name` / `auto_deploy`**:
  - デフォルトで `StageName: '$default'`、`AutoDeploy: true` の `AWS::ApiGatewayV2::Stage` が生成されます。

## API Gateway REST API (v1) と既存 API / OpenAPI 参照・統合 (REST API v1 & Existing API / OpenAPI Integration)

WAF 連携、プライベートエンドポイント、使用量プラン（API キー）などのエンタープライズ要件で API Gateway REST API (v1) が求められる場合、Application レベルで `rest_api` ブロックを宣言することで、既存の REST API ID・リソース ID の参照や OpenAPI スキーマからの統合定義を行い、`AWS::ApiGateway::Method`、`AWS::Lambda::Permission`、`AWS::ApiGateway::Deployment`、`AWS::ApiGateway::Stage` を自動生成できます。

```ruby
Veltrunode.application "enterprise-rest-api" do
  # 1. 既存 REST API ID とリソース ID の参照
  rest_api :corporate, rest_api_id: ref(:corporate_rest_api_id), stage_name: "prod" do
    tracing_enabled true
    stage_variables env: "production"

    get "/users", resource_id: ref(:users_resource_id), to: :list_users, api_key_required: true
    post "/users", resource_id: ref(:users_resource_id), to: :create_user,
                   authorization_type: :custom, authorizer_id: ref(:corp_authorizer_id)
  end

  # 2. OpenAPI スキーマ（S3 またはインライン）の参照・統合
  rest_api :openapi_gateway do
    openapi "s3://my-api-specs/openapi.yaml"
    stage "v1"

    get "/health", to: :health_check
  end

  function :list_users do
    handler "users.list"
    runtime "ruby3.3"
  end

  function :create_user do
    handler "users.create"
    runtime "ruby3.3"
  end
end
```

### パラメータ仕様

- **`rest_api_id` / `api_id`**: 既存の REST API ID（文字列または `ref(:param_name)`）。指定時は既存インフラストラクチャ保護ルールに従い `AWS::ApiGateway::RestApi` 本体を作成せず、その REST API に対して `Method`・`Deployment`・`Stage`・`Permission` を統合します。
- **`root_resource_id`**: デフォルトのリソース ID（メソッド単位で `resource_id` が省略された場合に使用）。
- **`openapi` / `openapi_spec` / `body`**: OpenAPI スキーマ定義（Hash、S3 URI `'s3://bucket/key'`、または `{ bucket: ..., key: ... }`）。`rest_api_id` 未指定時に `AWS::ApiGateway::RestApi` の `Body` または `BodyS3Location` として展開されます。
- **メソッド定義 (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `any`, `method`)**:
  - `resource_id`: 紐付け先の API Gateway リソース ID（文字列または `ref(:resource_id)`）。
  - `to`（エイリアス: `target`, `function`）: 統合先の Lambda 関数名（`AWS_PROXY` 統合）。
  - `authorization_type`（デフォルト: `'NONE'`）、`authorizer_id`、`api_key_required`（デフォルト: `false`）を指定可能。
- **`stage_name` / `stage`**: デプロイメントステージ名（デフォルト: `'prod'`）。`AWS::ApiGateway::Deployment`（全 `Method` への `DependsOn` 付き）および `AWS::ApiGateway::Stage` を生成します。

## Lambda Function URL と CORS・認証設定 (Lambda Function URL & CORS / AuthType)

API Gateway を介さず、低レイテンシかつシンプルに Webhook やマイクロサービスエンドポイントを公開する場合、`function` または `defaults` ブロックで `function_url` を定義することで、`AWS::Lambda::Url`、パブリックアクセス用の `AWS::Lambda::Permission`（`auth_type: :none` 時）、およびデプロイ出力（`Outputs`）の URL エンドポイントを自動構成できます。

```ruby
Veltrunode.application "function-url-app" do
  # 1. function キーワード引数での指定（パブリック Webhook + CORS）
  function :webhook, function_url: {
    auth_type: :none,
    cors: {
      allow_origins: ["https://example.com"],
      allow_methods: ["POST", "OPTIONS"],
      allow_headers: ["Content-Type", "X-Signature"],
      max_age: 86400
    }
  } do
    handler "webhook.handler"
    runtime "ruby3.3"
  end

  # 2. function ブロック内での指定（IAM 認証 + レスポンスストリーミング）
  function :internal_rpc do
    handler "rpc.handler"
    runtime "ruby3.3"
    function_url do
      auth_type :aws_iam
      invoke_mode :response_stream
      cors do
        origins "https://internal.example.com"
        methods "GET", "POST"
        allow_credentials true
      end
    end
  end
end
```

### パラメータ仕様

- **`auth_type` / `auth`**: 認証種別。`:none`（`'NONE'`: パブリックアクセス、デフォルト）または `:aws_iam` / `:iam`（`'AWS_IAM'`: AWS IAM 署名付きリクエストのみ許可）を指定します。
  - `:none` 指定時は、`Principal: '*'`、`Action: 'lambda:InvokeFunctionUrl'`、`FunctionUrlAuthType: 'NONE'` の `AWS::Lambda::Permission` が自動付与されます。
  - `:aws_iam` 指定時は、パブリックアクセス用の `AWS::Lambda::Permission` は生成されません。
- **`cors`**: `true`（全許可）、またはハッシュ/ブロック形式で `allow_origins`（`origins`）、`allow_methods`（`methods`）、`allow_headers`（`headers`）、`expose_headers`、`max_age`、`allow_credentials`（`credentials`）を指定します。
- **`invoke_mode`**: 呼び出しモード（`:buffered` -> `'BUFFERED'` または `:response_stream` -> `'RESPONSE_STREAM'`）。
- **デプロイ出力 (`Outputs`)**: `#{FunctionLogicalId}Url`（例: `WebhookFunctionUrl`）として `{ 'Fn::GetAtt' => ['WebhookFunctionUrl', 'FunctionUrl'] }` が `Outputs` に出力されます。

## CloudWatch メトリクスダッシュボード (CloudWatch Dashboard)

Application レベルで `dashboard` を宣言することで、デプロイされた全 Lambda 関数の稼働状態を一目で把握できる `AWS::CloudWatch::Dashboard` リソースを自動生成できます。

### 簡易指定
```ruby
Veltrunode.application "document-converter" do
  dashboard true
end
```
- デフォルトで主要4メトリクス（呼び出し数 `Invocations`、エラー数 `Errors`、実行時間 `Duration`、同時実行数 `ConcurrentExecutions`）のウィジェットが 2x2 グリッドで自動配置されます。
- アプリケーション内のすべての Lambda 関数が同一グラフ上に色分け表示されます。

### 詳細ウィジェット定義
```ruby
Veltrunode.application "document-converter" do
  dashboard :operations do
    title "Operations Overview"
    period 60 # 集約期間（秒）

    # 個別ウィジェット指定またはカスタマイズ
    invocations stat: "Sum", period: 60
    errors stat: "Sum", title: "Invocation Errors"
    duration stat: "p95"
    concurrent_executions stat: "Maximum"
  end
end
```

## SQS デッドレターキュー監視アラーム (SQS DLQ Message Alarm)

`schedule` ブロック内で `dlq`（または `dead_letter_queue`）を定義する際、`alarm: true` を指定することで、DLQ にメッセージが蓄積されたことを検知する `AWS::CloudWatch::Alarm` リソースを自動生成できます。

```ruby
Veltrunode.application "document-converter" do
  schedule :nightly do
    target :convert
    cron "0 1 * * ? *", timezone: "Asia/Tokyo"
    input source: "nightly"
    retry maximum_attempts: 2, maximum_event_age: 7200

    # 1. 簡易指定（自動生成キュー + 即時アラーム発報）
    dlq :nightly_dlq, alarm: true, topic: ref(:alert_topic)

    # またはブロック構文
    # dlq :nightly_dlq do
    #   alarm true
    #   topic ref(:alert_topic)
    # end
  end
end
```

- **`alarm: true`**: `ApproximateNumberOfMessagesVisible > 0`（即時発報: Period 60秒、EvaluationPeriods 1、Statistic: Maximum）の CloudWatch Alarm を自動展開。
- **`topic`**: アラーム発報時の通知先 SNS トピック ARN または `ref(...)` 参照。
- **統一プレフィックス規約**: 生成されるアラームの `AlarmName` には、スタック名に基づいたプレフィックス `{ 'Fn::Sub' => "${AWS::StackName}-#{LogicalId}" }` が自動適用されます。

## エスケープハッチ (Escape Hatch)

初期フェーズ以降に、管理された `cloudformation_patch` 機能が導入される予定です（設計方針の詳細は [ADR-0003](adr/0003-cloudformation-patch-escape-hatch.md) を参照）。これは、既存の論理リソースをターゲットにし、スキーマ検証およびセキュリティポリシー検証を通過する必要があります。テンプレート全体の任意の置き換えはサポートされません。
