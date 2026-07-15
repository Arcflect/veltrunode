# ロードマップ (Roadmap)

## フェーズ 0 - リポジトリの基盤構築 (Phase 0 - Repository Foundation)

名称調査、ライセンス、クリーンルーム開発ポリシー、アーキテクチャ設計決定、Gemのスケルトン作成、CI環境整備、リリース自動化、貢献ガイド。

## フェーズ 1 - コンパイルとビルド (Phase 1 - Compile and Build)

Ruby DSL、型付きモデル、Lambda、既存のEFSアクセスポイント参照、Layer、Scheduler、IAM、ログ、SQS DLQ、決定論的ビルド、CloudFormation出力、バリデーション。

## フェーズ 2 - 安全なデプロイ (Phase 2 - Safe Deployment)

S3アーティファクトのアップロード、変更セット（Change Set）による計画表示、デプロイ、保護対象ステージの制御、AWSアカウント確認、JSON形式の出力、ロールバック診断。

## フェーズ 3 - 運用の差別化機能 (Phase 3 - Operational Differentiators)

`efs verify`（EFS接続診断）、スケジュール実行プレビュー、Layerの検査と再利用、保持ポリシーのドライラン、詳細なパッケージングレポートの提供。

## フェーズ 4 - アクセスポイントの自動管理 (Phase 4 - Managed Access Points)

任意のEFSアクセスポイント自動作成機能、セキュリティグループ作成ヘルパー、インポートしたインフラ構成との契約管理。

## 正式リリース基準 (Criteria for Official Release)

DSLの安定化、移行ポリシーの確立、ドキュメント化された互換性マトリクス、実運用リファレンス、セキュリティレビューの実施、署名付きリリース、および後方互換性コミットメント。
