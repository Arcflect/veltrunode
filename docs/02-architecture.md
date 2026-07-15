# アーキテクチャ設計 (Architecture Design)

## 処理パイプライン (Processing Pipeline)

```text
Veltrunodefile
  -> DSL評価器 (DSL evaluator)
  -> 型付きアプリケーションモデル (typed application model)
  -> 参照解決器 / リソースグラフ (reference resolver / resource graph)
  -> バリデータおよびポリシーチェック (validators and policy checks)
  -> ビルダー (builders)
  -> アーティファクトストア (artifact store)
  -> CloudFormationコンパイラ (CloudFormation compiler)
  -> template.yml + manifest.json
  -> CloudFormation変更セット (CloudFormation change set)
  -> デプロイ実行器 (deploy executor)
```

## コンポーネント (Components)

### CLI
ユーザーの意図をパースし、設定をロードしてアプリケーションサービスを呼び出し、診断結果をフォーマットして出力します。CLIコンポーネント自体にAWSリソースの生成ロジックを含めてはなりません。

### DSL ファサード (DSL Facade)
型付きの宣言（モデル）を生成する軽量なRuby APIです。DSLメソッドはビルド処理を委譲するだけであり、CloudFormationのハッシュ構造を直接操作しません。

### ドメインモデル (Domain Model)
Application、Function、Layer、Schedule、FileSystemMount、AccessPointReference、Permission、Artifact、StagePolicyなどの不変（または事実上不変の）オブジェクト群です。

### リソースグラフ (Resource Graph)
シンボリックな参照を解決し、依存関係の循環を検出し、ビルド順序を決定し、CloudFormationコンパイラに対して依存関係のエッジ情報を提供します。

### ビルドサブシステム (Build Subsystem)
関数のZIPおよびLayerのZIPファイルを作成します。Bundlerを実行し、コンテナを使用したネイティブビルドを処理し、ファイルの包含/除外ルールを適用し、コンテンツハッシュを計算します。

### バリデータ (Validators)
アプリケーションモデルに対して動作する、純粋な検証チェック機能です。AWSのリソース状態に依存する診断ロジックは、インスペクターサブシステムとして分離されます。

### AWS インスペクター (AWS Inspectors)
`efs verify`、アカウントチェック、既存リソースの検証、および変更セットの検証で使用される、AWS SDKの読み取り専用クライアント群です。

### CloudFormation コンパイラ (CloudFormation Compiler)
型付きのドメインリソースを標準のCloudFormationにマッピングします。正規化されたモデルとアーティファクトのハッシュ値が同一である限り、コンパイル結果は常に決定的（再現可能）でなければなりません。

### デプロイ実行器 (Deployment Executor)
アーティファクトをアップロードし、変更セット（Change Set）を作成または更新し、リソースの準備完了を待機し、必要に応じて承認を要求し、変更セットを実行します。

## 推奨されるGem構成 (Suggested Gem Structure)

```text
lib/veltrunode/
  cli/
  dsl/
  model/
  graph/
  validation/
  build/
  compiler/cloudformation/
  aws/inspectors/
  deploy/
  diagnostics/
```

最初は単一のGemとして開始し、独立したリリースサイクルが正当化される場合にのみ分割を検討してください。
