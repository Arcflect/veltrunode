# Veltrunode

定期バッチ処理やファイル処理を行うAWS Lambdaアプリケーション向けの、Rubyファーストなツールキット。

Veltrunodeは、RubyのDSLからレビュー可能なAWS CloudFormationテンプレートをコンパイルして出力します。また、以下のリソースを中心としたビルド、検証、変更セット（Change Set）作成、およびデプロイのワークフローを提供します。

- AWS Lambda
- Amazon EventBridge Scheduler
- AWS Lambda Layers
- Amazon EFS アクセスポイントおよびマウント設定
- IAM、CloudWatch Logs、SQS デッドレターキュー（DLQ）、VPCおよびセキュリティグループの統合

本プロジェクトは、意図的に一般的なサーバーレスデプロイツールの汎用的なクローンを目指していません。LayerパッケージングやEFS接続の設定が運用上難しくなりがちな、定期的なバッチジョブやファイル処理のワークロードに焦点を絞っています。

## ステータス

設計段階のOSSプロジェクトです。APIはまだ安定していません。

## 設計原則

- **AWSネイティブ出力**: CloudFormationテンプレートを第一級のビルドアートファクトとして扱います。
- **SaaS不要**: 独自のSaaSアカウント、テレメトリ収集サービス、または独自のプロプライエタリな状態管理バックエンドを強制しません。
- **Rubyファーストなパッケージング**: Bundlerの統合やネイティブ拡張機能のビルドなど、Rubyに最適化されたパッケージングを提供します。
- **デフォルトで安全なデプロイ**: 事前検証（Validate）とCloudFormationの変更セット（Change Set）を活用し、安全なデプロイをサポートします。
- **既存インフラの参照**: リソースをすべて再作成するのではなく、既存のインフラストラクチャを簡単に参照できる設計を優先します。
- **クリーンルーム開発**: AWSの公式公開仕様および独立して記述された要件に基づいてクリーンに設計・実装します。

## 設定例 (DSL)

```ruby
Veltrunode.application "daily-sales-import" do
  aws region: "ap-northeast-1", stage: ENV.fetch("STAGE", "dev")
  runtime ruby: "3.4", architecture: :arm64

  layer :gems do
    bundle lockfile: "Gemfile.lock", without: %i[development test]
    build_on :amazon_linux_2023
  end

  efs_mount :shared do
    access_point arn: ENV.fetch("EFS_ACCESS_POINT_ARN")
    local_path "/mnt/shared"
  end

  function :import_sales do
    handler "functions/import_sales.handler"
    memory 2048
    timeout 900
    attach_layer :gems
    mount :shared
  end

  schedule :daily_import do
    target :import_sales
    cron "0 2 * * ? *", timezone: "Asia/Tokyo"
    retry maximum_attempts: 2, maximum_event_age: 3600
  end
end
```

## 提供予定のCLIコマンド

```bash
veltrunode init
veltrunode validate
veltrunode build
veltrunode plan
veltrunode deploy
veltrunode destroy
veltrunode schedule preview NAME
veltrunode layer inspect NAME
veltrunode efs verify NAME
```

## ドキュメント

詳細な設計書については、[docs/Veltrunode_Public_Design.md](docs/Veltrunode_Public_Design.md) をご参照ください。

## CI とブランチ保護

Pull Request と `main` ブランチへの push では、GitHub Actions の CI が自動実行されます。CI では以下を検証します。

- `rspec`: Ruby 3.2, 3.3, 3.4, 4.0 を `ubuntu-latest` と `macos-latest` のマトリクスで実行
- `rubocop`: 静的解析の実行
- `gem-build`: `veltrunode.gemspec` からの Gem ビルド検証

`main` ブランチでテスト失敗時のマージをブロックするには、GitHub リポジトリで以下を設定してください。

1. GitHub の `Settings` を開く
2. `Branches` から `main` 向けの branch protection rule を作成または編集する
3. `Require a pull request before merging` を有効化する
4. `Require status checks to pass before merging` を有効化する
5. 必須チェックとして `RuboCop` と `Gem Build`、および各 `RSpec (...)` マトリクスチェックを選択する

ブランチ保護を有効にすると、いずれかの CI ジョブが失敗した Pull Request は `main` にマージできません。