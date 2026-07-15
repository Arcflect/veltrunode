**Veltrunode**

*Ruby-first toolkit for AWS Lambda / EventBridge Scheduler / Lambda Layers / EFS*

Design Package - 2026-07-15

---

# 1. エグゼクティブサマリー

Veltrunodeは、定期バッチおよびファイル処理型のAWS Lambdaアプリケーションを対象に、Ruby DSLからCloudFormation、関数ZIP、Lambda Layer、マニフェストを生成し、検証・変更差分確認・デプロイを行うOSSツールである。対象をLambda、EventBridge Scheduler、Lambda Layer、EFS連携に集中させ、広範なサーバーレスフレームワークの模倣ではなく、EFS接続診断とRuby Layerライフサイクルを中核の独自価値とする。

# 2. 背景と課題

LambdaとEventBridge Schedulerを使った定期処理では、関数だけでなく、Scheduler実行ロール、Lambda実行ロール、Layer、EFSアクセスポイント、VPC、サブネット、セキュリティグループ、NFS 2049、CloudWatch Logs、DLQなどを整合させる必要がある。特にEFSは構成要素を横断するため、デプロイ後のマウント失敗として問題が顕在化しやすい。

# 3. 製品境界

初期対象範囲はRuby Lambda、Scheduler、Layer、既存EFSアクセスポイント、IAM、Logs、SQS DLQ、CloudFormationに限定する。API GatewayやStep Functionsなどは初期対象外とし、外部インフラ管理ツール等が管理する既存インフラを参照できる設計を優先する。

# 4. 基本アーキテクチャ

VeltrunodefileをDSL評価し、型付きアプリケーションモデルへ変換する。参照解決とリソースグラフ検証を行い、ビルドサブシステムが関数・Layer成果物を生成する。CloudFormationコンパイラが標準リソースへ変換し、planはCloudFormation Change Setを利用する。

# 5. 中核ドメイン

Application、Function、Layer、Schedule、EfsMount、Permission、Artifact、StagePolicyを主要モデルとする。DSLはモデル生成のファサードであり、CloudFormationのHashを直接操作しない。これにより、検証、決定的コンパイル、将来の入力形式追加を可能にする。

# 6. EFS診断

efs verifyはアクセスポイント、ファイルシステム、VPC一致、マウントターゲット、到達可能なAZ、Lambda側SGの2049 outbound、EFS側SGの2049 inbound、POSIX UID/GID、ルートディレクトリ、IAM権限を読取APIで確認する。判定不能な項目は証拠と確信度を示し、成功を保証したような表現を避ける。

# 7. Lambda Layer管理

Gemfile.lock、Bundlerグループ、Rubyランタイム、アーキテクチャ、ビルドイメージ、対象ファイルからコンテンツIDを生成する。同一内容は検証済みLayer Versionを再利用する。ネイティブGemはAmazon Linux互換コンテナで構築し、ビルドイメージのdigestをマニフェストへ記録する。

# 8. Scheduler管理

cron、rate、one-time、timezone、flexible window、retry、maximum event age、DLQ、JSON inputを扱う。schedule previewにより次回実行時刻とDST影響を表示する。SchedulerのLambda呼び出しロールは原則として対象関数だけに絞る。

# 9. セキュリティ

標準AWS SDK認証チェーンを使用し、認証情報を収集しない。デプロイ前にAWSアカウントとリージョンを照合する。IAMの高水準capabilityは、バージョン管理された展開結果をplanとmanifestに表示する。本番ポリシーではワイルドカードやDLQ欠落を拒否できる。

# 10. Clean-room方針

既存のサーバーレスデプロイツール等のソースコード、テスト、内部ライフサイクル、プラグインAPI、設定スキーマ、エラーメッセージ、ドキュメント表現をコピーまたは機械的に翻案しない。AWS公開仕様、独立したユーザー要件、一般的設計パターンから設計し、IssueとADRで出自を記録する。

# 11. 名称調査

作業名称はVeltrunode。2026年7月15日時点の完全一致検索ではGitHub、RubyGems、npm、PyPI、crates.io、一般Webで一致を確認できなかった。ただし検索漏れ、非公開利用、将来登録、国・区分別商標権があるため、絶対的な非衝突は保証できない。公開直前にJ-PlatPat、WIPO、USPTO、EUIPOを含む再調査と名称予約を行う。

# 12. ロードマップ

第一段階でDSL、モデル、ビルド、CloudFormation生成を実装し、第二段階でChange Setベースの安全なデプロイ、第三段階でEFS verify、Layer再利用、schedule previewを実装する。正式リリースは安定DSL、互換性方針、実運用事例、セキュリティレビュー、署名付きリリースを条件とする。

# 13. DSL例

```ruby
Veltrunode.application "daily-sales-import" do
  aws region: "ap-northeast-1", stage: ENV.fetch("STAGE", "dev")
  runtime ruby: "3.4", architecture: :arm64

  layer :gems do
    bundle lockfile: "Gemfile.lock", without: %i[development test]
    build_on :amazon_linux_2023
  end

  efs_mount :shared do
    existing_access_point arn: ENV.fetch("EFS_ACCESS_POINT_ARN")
    local_path "/mnt/shared"
  end

  function :import_sales do
    handler "functions/import_sales.handler"
    memory 2048
    timeout 900
    attach_layer :gems
    mount :shared
  end

  schedule :daily do
    target :import_sales
    cron "0 2 * * ? *", timezone: "Asia/Tokyo"
  end
end
```

