# 対象範囲と要件 (Scope and Requirements)

## 初期対象リソース (MVP Resources)

- `AWS::Lambda::Function`
- `AWS::Lambda::LayerVersion`
- `AWS::Logs::LogGroup`
- `AWS::Scheduler::Schedule`
- `AWS::IAM::Role` および `AWS::IAM::Policy`
- 必要に応じた `AWS::Lambda::Permission`
- 既存または新規生成される `AWS::EFS::AccessPoint`（オプション）
- `AWS::EFS::FileSystem`（初期フェーズ以降での対応を検討）
- 自動生成される `AWS::EC2::SecurityGroup`（オプション）
- デッドレター（DLQ）配信用の `AWS::SQS::Queue`
- S3アーティファクトバケットの参照
- サポート対象ランタイム: Ruby、Python、Node.js

## 機能要件 (Functional Requirements)

- **FR-001**: 任意のデプロイ処理を実行することなく、Rubyのアプリケーション定義をパースできること。
- **FR-002**: リソース名、参照関係、ランタイム互換性、ファイルパス、IAM宣言、および依存関係の循環を検証できること。
- **FR-003**: サポート対象ランタイム（Ruby、Python、Node.js）の関数コードと依存関係を再現可能な形でパッケージングできること。
- **FR-004**: ネイティブモジュールやネイティブGem等をAmazon Linux互換コンテナ内でビルドできること。
- **FR-005**: 関数およびLayerアーティファクトに対して、決定論的なコンテンツハッシュ値を生成できること。
- **FR-006**: 各リソースをCloudFormationのYAMLおよび機械読取可能なマニフェストファイルにコンパイルできること。
- **FR-007**: 変更セット（Change Set）を使用して、CloudFormationの変更内容をプレビューできること。
- **FR-008**: 保護されたステージにおいて、検証の成功と明示的な承認が得られた場合にのみデプロイを実行すること。
- **FR-009**: EventBridge Schedulerの cron、rate、one-time（一回限り）スケジュール、タイムゾーン、柔軟な実行ウィンドウ（flexible window）、再試行ポリシー、およびDLQをサポートすること。
- **FR-010**: 既存または生成されたEFSアクセスポイントと、`/mnt/` 配下でのLambdaマウントをサポートすること。
- **FR-011**: AWSの読取専用APIを使用して、EFS接続の前提条件を診断（診断ツール）できること。
- **FR-012**: コンテンツハッシュに基づき、変更のないLayerバージョンを再利用すること。
- **FR-013**: 明示的な保持ポリシーに従って、古いLayerバージョンをクリーンアップ（Prune）すること。
- **FR-014**: AWSアカウントおよびリージョンの不整合（誤操作デプロイ）を防止すること。
- **FR-015**: 恒久的なエラーコードとともに、即座に対処可能なエラー診断情報を出力すること。

## 初期フェーズの対象外 (Out of Scope)

API Gateway、AppSync、Cognito、Kinesis、ECS、Step Functions、CloudFront、一般的なすべてのCloudFormationリソース編集、および既存の他のサーバーレスデプロイツールのプラグイン互換性。
