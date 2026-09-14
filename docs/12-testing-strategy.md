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

`rantly`（`rantly/rspec_extensions`）を用いたプロパティベーステストにより、ランダムかつ多様な入力組み合わせに対して、以下の不変条件（Properties）が常に維持されることを検証します。

### 検証対象の主要プロパティ (`spec/property_spec.rb`)

1. **CloudFormation出力の決定性（Compilation Determinism）**
   - 同一のアプリケーションモデル・関数・スケジュール・IAMケーパビリティ設定に対して、複数回コンパイル（`to_yaml` および `compile`）を行っても、完全一致する同一の CloudFormation テンプレート YAML およびハッシュが出力されることを検証します。
2. **マップキーの安定ソート順序（Map Key Stable Sorting）**
   - 任意の深さを持つネストされた辞書構造に対して、`TemplateCompiler#deep_sort_keys` を通すことですべてのキーが文字列化され、アルファベット順に安定ソートされることを検証します。
3. **ファイルパスの正規化（Path Normalization）**
   - 冗長なスラッシュ（`//`）、カレントディレクトリ表現（`./`）、末尾スラッシュの除去が安全かつ冪等に行われること（`normalize(normalize(p)) == normalize(p)`）、および相対パス・絶対パスの種別が保持されることを検証します（`Veltrunode::PathNormalizer`）。
4. **論理ID生成の一意性と妥当性（Logical ID Uniqueness and Validity）**
   - 任意の名前文字列から生成される CloudFormation 論理ID（`LogicalId.for`）が英字開始の英数字（`\A[A-Z][a-zA-Z0-9]*\z`）に正規化されること、同一タイプ内での異なるシンボリック名同士が重複しないこと、および同一名称であっても異なるリソースタイプ間で一意のIDが割り振られることを検証します。
5. **参照解決の冪等性（Reference Resolution Idempotency）**
   - 複数関数、Layer、EFSマウント、スケジュール等が複雑に相互参照するアプリケーションモデルにおいて、リソースグラフ（`Veltrunode::Graph::ResourceGraph`）のトポロジカルソート順序や依存関係解決が状態変化を伴わず常に冪等・安定して評価されることを検証します。

### テストの実行

プロパティテスト単体の実行:
```bash
bundle exec rspec spec/property_spec.rb
```

テストスイート全体の一部としても実行されます:
```bash
bundle exec rspec
```

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
