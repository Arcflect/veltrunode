# ロードマップ (Roadmap)

## フェーズ 0 - リポジトリの基盤構築 (Phase 0 - Repository Foundation)

名称調査、ライセンス、クリーンルーム開発ポリシー、アーキテクチャ設計決定、Gemのスケルトン作成、CI環境整備、リリース自動化、貢献ガイド。

## フェーズ 1 - コンパイルとビルド (Phase 1 - Compile and Build)

Ruby DSL、型付きモデル、Lambda、既存のEFSアクセスポイント参照、Layer、Scheduler、IAM、ログ、SQS DLQ、決定論的ビルド、CloudFormation出力、バリデーション。

## フェーズ 2 - 安全なデプロイ (Phase 2 - Safe Deployment)

S3アーティファクトのアップロード、変更セット（Change Set）による計画表示、デプロイ、保護対象ステージの制御、AWSアカウント確認、JSON形式の出力、ロールバック診断。

## フェーズ 3 - 運用の差別化機能 (Phase 3 - Operational Differentiators)

`efs verify`（EFS接続診断）、スケジュール実行プレビュー、Layerの検査と再利用、保持ポリシーのドライラン、詳細なパッケージングレポートの提供、本番ポリシーパック（セキュリティベストプラクティス強制・カスタムポリシー定義）。

## フェーズ 4 - アクセスポイントの自動管理 (Phase 4 - Managed Access Points)

任意のEFSアクセスポイント自動作成機能（`managed_access_point` DSL、POSIX UID/GID・ルートディレクトリ設定、Lambda自動紐付け）、セキュリティグループ作成ヘルパー、インポートしたインフラ構成との契約管理。

## フェーズ 5 - 本番運用性・監視・オブザーバビリティ (Phase 5 - Observability & Operations)

CloudWatch Alarms 自動生成 DSL（`alarms` 定義）、Logs サブスクリプションフィルター、AWS X-Ray / ADOT (OpenTelemetry) 分散トレーシング、CloudWatch Dashboard 生成、Lambda Insights、非同期呼び出しリトライ・DLQ監視アラーム、リアルタイムログストリーミング（`veltrunode tail`）、メトリクス集計（`veltrunode metrics`）。

## フェーズ 6 - イベントソース・トリガー拡張 (Phase 6 - Event Sources & Ingestion)

SQS イベントソースマッピング（バッチサイズ・部分失敗報告）、SNS トピックサブスクリプション、S3 イベント通知トリガー、DynamoDB Streams、EventBridge カスタムイベントバストリガー、API Gateway HTTP API (v2) 統合 DSL、API Gateway REST API (v1) 統合、Lambda Function URL、Kinesis Data Streams、MSK / MQ イベントソース統合。

## フェーズ 7 - EFS・ストレージ・ステートフルワークロード深化 (Phase 7 - Advanced EFS & Storage)

EFS ライフサイクルポリシー（IA / Archive 移行）、スループットモード（Provisioned / Elastic）、AWS Backup 自動化連携、複数 EFS ファイルシステムの同時マウント、EFS I/O 枯渇監視アラーム、クォータ確認 CLI（`veltrunode efs quota`）、性能ベンチマーク CLI（`veltrunode efs bench`）、KMS CMK 暗号化、EFS ファイルシステム自体の自動作成（`managed_file_system` DSL）、クロスリージョン EFS レプリケーション。

## フェーズ 8 - ビルド・パッケージング・コンテナ・ランタイム強化 (Phase 8 - Advanced Build & Runtimes)

Lambda OCI コンテナイメージパッケージング（`image` DSL / ECR プッシュ自動化）、ARM64 (Graviton2/3) 完全サポート、Rust / Go カスタムランタイム (provided.al2023) ビルド、Node.js (esbuild / Bun) バンドラー統合、Python (uv / Poetry) 仮想環境レイヤー生成、Dockerless ビルドモード、Layer 依存関係ツリー可視化（`veltrunode layer tree`）、Sigstore / Cosign によるアーティファクト署名、ローカル LRU キャッシュ Prune、マルチアーキテクチャマトリクスビルド。

## フェーズ 9 - 高度なデプロイ・CI/CD・安全機能 (Phase 9 - Advanced Deployment & CI/CD)

CodeDeploy によるカナリアデプロイ（Linear / Canary トラフィックシフト）、Lambda エイリアス & バージョニング完全サポート、Blue/Green デプロイメント DSL、公式 GitHub Actions、デプロイライフサイクルフック（pre_deploy / post_deploy）、複数スタック依存管理（Multi-Stack Orchestration）、DynamoDB / S3 によるデプロイメントロック、CloudFormation ドリフト検出（`veltrunode drift detect`）、ローカル差分表示（`veltrunode diff`）、ロールバック時自動通知。

## フェーズ 10 - セキュリティ・ガバナンス・コンプライアンス (Phase 10 - Security & Governance)

静的コード解析による IAM 最小権限自動推論、AWS Organizations / SCP ガードレール検証、KMS CMK 暗号化サポート、Secrets Manager / SSM Parameter Store 参照 DSL、VPC 構成ヘルパー、静的セキュリティスキャン統合（Brakeman / Semgrep）、SBOM 脆弱性スキャン CLI（`veltrunode scan` / Trivy 連携）、CI 向け OIDC ロール自動生成、CIS AWS Foundations 準拠レポート、緊急キルスイッチ CLI（`veltrunode emergency stop`）。

## フェーズ 11 - 開発者体験・ローカルエミュレーション (Phase 11 - Developer Experience & Tooling)

ローカル EFS エミュレーション（Docker NFS コンテナ）、ホットリロード対応ローカル開発サーバー（`veltrunode dev`）、対話型 REPL 環境（`veltrunode console`）、VS Code 拡張機能、Language Server Protocol (LSP) 実装、ユースケース別雛形生成（`veltrunode scaffold`）、シェル自動補完スクリプト、環境整合性診断（`veltrunode doctor`）、OpenAPI 定義インポートツール、ローカルモックイベント生成ユーティリティ。

## フェーズ 12 - コスト最適化・FinOps (Phase 12 - Cost Optimization & FinOps)

月額コスト予測 CLI（`veltrunode cost estimate`）、AWS Lambda Power Tuning 自動統合、遊休リソース検出（`veltrunode cost audit`）、EFS ライフサイクルコスト削減シミュレータ、コスト配分タグ自動伝播、プロビジョンドコンカレンシーのスケジュールスケーリング、SnapStart 有効化サポート、CloudWatch Logs 保持期間最適化サジェスト、x86_64 vs Graviton コスト性能比較、同時実行数上限ガード。

## フェーズ 13 - テスト・品質・信頼性工学 (Phase 13 - Testing & Reliability)

カオスエンジニアリング（EFS 遅延・障害注入テスト支援）、コールドスタート・ウォームスタート性能ベンチマーク、負荷テスト自動化（k6 / Locust 連携）、コンシューマ主導契約テスト（Pact 等）、エフェメラル検証環境自動作成（`veltrunode test ephemeral`）、CloudFormation スナップショット比較テスト強化、AWS FIS 実験テンプレート自動生成、マルチ AZ 障害シミュレーション、並列リグレッションテスト CI 強化、ミューテーションテスト（Mutant）導入。

## フェーズ 14 - エコシステム・プラグイン・エンタープライズ拡張 (Phase 14 - Ecosystem & Enterprise)

プラグインアーキテクチャ（ライフサイクルフックとカスタムコンパイラ拡張）、Terraform / OpenTofu 向け HCL エクスポート、AWS CDK / Pulumi 相互運用モジュール、Datadog / New Relic APM Layer 自動統合、Sentry / Honeycomb エラートラッキング、マルチアカウント・マルチリージョン並行デプロイ（`veltrunode matrix deploy`）、プライベート Gem / Layer レジストリ連携、Webhook 通知（Slack / Teams / Discord）、CMDB メタデータエクスポート、公式ドキュメントポータル自動更新。

## 正式リリース基準 (Criteria for Official Release)

DSLの安定化、移行ポリシーの確立、ドキュメント化された互換性マトリクス、実運用リファレンス、セキュリティレビューの実施、署名付きリリース、および後方互換性コミットメント。
