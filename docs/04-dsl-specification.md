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

## エスケープハッチ (Escape Hatch)

初期フェーズ以降に、管理された `cloudformation_patch` 機能が導入される可能性があります。これは、既存の論理リソースをターゲットにし、スキーマ検証を通過する必要があります。テンプレート全体の任意の置き換えはサポートされません。
