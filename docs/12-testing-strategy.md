# テスト戦略 (Testing Strategy)

## ユニットテスト (Unit Tests)

以下のコンポーネントに対するテストを実施します。
- DSLビルダー、ドメインモデルの不変条件（Invariants）、リソースグラフの解決ロジック
- バリデータ、論理ID（Logical ID）の生成ロジック
- IAMケーパビリティの展開、cron式のパース、パッケージングルール
- エラー診断のフォーマット出力

## ゴールデンテスト (Golden Tests)

定義済みのテスト用 `Veltrunodefile` を使用し、レビュー済みの CloudFormation テンプレート（`template.yml`）およびマニフェストファイル（`manifest.json`）へのコンパイルをテストします。

### フィクスチャの配置 (`spec/fixtures/golden/`)
各テストパターンのディレクトリ配下に `Veltrunodefile`、期待される `template.yml`、期待される `manifest.json` を配置します。

- `minimal/`: 最小構成（関数1つ、スケジュール1つ）
- `with_layer/`: Layer付き構成（カスタムレイヤー、アーキテクチャ指定）
- `with_efs/`: EFSマウント付き構成（AccessPoint ARN、VPC設定、マウントパス）
- `multiple_resources/`: 複数関数・複数スケジュール構成（ログ保持、タグ、同時実行数、リトライ/DLQ）
- `with_iam_capabilities/`: IAMケーパビリティ付き構成（S3読み書き、SSMパラメータ、SNS発行）

### テストの実行とフィクスチャの更新

通常実行（差分検出）:
```bash
bundle exec rspec spec/golden_spec.rb
```

フィクスチャ更新:
```bash
UPDATE_GOLDEN=1 bundle exec rspec spec/golden_spec.rb
```

### Git差分レビューの要求
仕様変更やコンパイラの改修により出力結果に変更が発生した場合は、`UPDATE_GOLDEN=1` によりフィクスチャを意図的に更新した上で、必ず `git diff spec/fixtures/golden/` を実行し、生成される CloudFormation テンプレートおよびマニフェストの差分に対するセマンティックなレビューを行ってください。

## プロパティテスト (Property Tests)

生成されるインプット値の多様な組み合わせにわたって、決定論的な（再現可能な）コンパイル、安定したマップソート順序、パスの正規化、および参照解決をテストします。

## 統合テスト (Integration Tests)

- コンテナ環境内での Ruby 関数および Layer のビルド。
- 分離されたテスト用の AWS アカウントに対する、最小限の CloudFormation スタックのデプロイ。
- 一時的な一回限り（one-time）のスケジュールを使用した、ターゲット関数の実行テスト。
- 実際に EFS をマウントし、ファイルの読み書き動作を検証。
- 意図的に NFS 接続を遮断したり、無効な POSIX 構成を設定したりした状態での、エラー診断機能の動作テスト。

## 互換性マトリクス (Compatibility Matrix)

サポート対象の Ruby バージョン、Bundler バージョン、CPUアーキテクチャ（`x86_64` / `arm64`）、サポート対象の Lambda ランタイム、LinuxおよびmacOSの開発者環境、ならびに CI ランナー環境を対象にテストを実行します。

## リリース基準 (Release Gates)

すべてのテスト、RuboCop、型チェック（導入している場合）、ドキュメントのコード例の実行、Gemのビルド、脆弱性スキャン、およびスモークデプロイテストがパスすることをリリース基準とします。
