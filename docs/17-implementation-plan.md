# 実装計画 (Implementation Plan)

## マイルストーン 1: スケルトン作成 (Milestone 1: Skeleton)

Gem仕様の定義、CLIコマンドルーター、設定ロード処理、診断用オブジェクト、RSpec、RuboCop、GitHub Actions、リリースワークフローの構築。

## マイルストーン 2: モデルと DSL (Milestone 2: Model and DSL)

Application、Function、Layer、Schedule、EFSマウント設定、IAMケーパビリティ宣言、参照、不変モデルの作成、およびバリデーションエラーの実装。

## マイルストーン 3: パッケージング (Milestone 3: Packaging)

関数の ZIP ファイル化、Bundler用 Layer、Docker を用いたネイティブビルド、決定論的なアーカイブの生成、マニフェスト出力、キャッシュ機構の実装。

## マイルストーン 4: コンパイラ (Milestone 4: Compiler)

Lambda、LayerVersion、LogGroup、Scheduler、IAMロール、権限、EFSマウント構成、SQS DLQ、パラメータ、および出力（Outputs）のCloudFormation変換ロジックの実装。

## マイルストーン 5: AWS デプロイ (Milestone 5: AWS Deployment)

アーティファクト保存用のS3バケット連携、変更セット（Change Set）、プラン描画、実行・待機ロジック、AWSアカウントおよびリージョンのガード機能の実装。

## マイルストーン 6: 差別化機能 (Milestone 6: Differentiators)

EFS接続診断（EFS Verifier）、Layerの再利用と検査、スケジュール実行プレビュー、本番向けポリシーパックの実装。

## 推奨される最初の Issue 項目 (Suggested First Issues)

1. 診断用オブジェクトおよび恒久的なエラーコードの形式定義。
2. DSLに依存しないアプリケーションモデルの単体実装。
3. 参照グラフの解決ロジックの実装。
4. 単一の Lambda 関数および Log Group のコンパイルの実装。
5. 決定論的な ZIP アーカイブ生成の概念実証（PoC）。
6. 単一の Bundler Layer のコンパイルの実装。
7. 単一の Scheduler ターゲットおよびロールのコンパイルの実装。
8. 既存の EFS アクセスポイントマウントのコンパイルの実装。
9. デプロイ時の AWS アカウントガード機能の実装。
10. EFS の NFS セキュリティグループインスペクター（診断機能）の実装。
