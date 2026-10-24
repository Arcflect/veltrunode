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

## エスケープハッチ (Escape Hatch)

初期フェーズ以降に、管理された `cloudformation_patch` 機能が導入される予定です（設計方針の詳細は [ADR-0003](adr/0003-cloudformation-patch-escape-hatch.md) を参照）。これは、既存の論理リソースをターゲットにし、スキーマ検証およびセキュリティポリシー検証を通過する必要があります。テンプレート全体の任意の置き換えはサポートされません。
