# アーキテクチャ設計 (Architecture Design)

> **内部開発モデル**: Veltrunode は AWS Lambda を中心としたサーバーレスデプロイツールです。
> 内部実装では **Transparent Compiler Architecture** を開発モデルとして採用しています（[ADR-0002](adr/0002-transparent-compiler-architecture.md)）。
> これは Veltrunode をコンパイラ製品として位置付けるものではなく、内部処理の責務境界を明確にするための設計モデルです。

## 処理パイプライン (Processing Pipeline)

```text
Veltrunodefile
      │
      ▼
   DSL Layer            # Veltrunodefile の評価・解析
      │
      ▼
Normalization           # 型付き内部モデルへの正規化
      │
      ▼
Internal Model          # Application / Function / Layer / Schedule / EfsMount 等
      │
      ├── Validation              # モデルの純粋な検証チェック
      │
      ├── Dependency Resolution   # シンボリック参照の解決・循環検出
      │
      ├── Diagnostics             # 診断結果の収集と構造化
      │
      └── Policy                  # ステージポリシーチェック
      │
      ▼
Artifact / Infrastructure Compiler
      │
      ├── CloudFormation Compiler # 型付きモデル → CloudFormation テンプレート
      │
      └── Build Subsystem         # 関数 ZIP / Layer ZIP の生成（決定論的）
      │
      ▼
Deployment Plan         # 変更セット（Change Set）の作成
      │
      ▼
AWS Deployment          # S3 アップロード / CloudFormation 変更セット実行
      │
      ▼
      AWS
```

## コアとなる設計原則 (Core Development Principles)

詳細は [docs/20-transparent-compiler-architecture.md](20-transparent-compiler-architecture.md) を参照。

1. **Internal Model First** — DSL / CLI 入力はそのまま AWS 処理へ渡さず、必ず内部モデルへ変換する
2. **Separate Definition from Execution** — 「何を作るか」と「実際に作る処理」を分離する
3. **Deterministic Transformation** — 同じ入力から常に同じ内部モデルおよびデプロイ成果物を生成する
4. **Explicit Side Effects** — AWS API / File System などの副作用を明確な境界へ隔離する
5. **Validation Before Deployment** — 可能な問題はデプロイ前に検出する
6. **Inspectable Intermediate State** — 内部処理をブラックボックス化しない
7. **Dependency Direction** — 依存方向を一方向（CLI → Application → Domain → Compiler → AWS Adapter）に固定する

## 依存方向 (Dependency Direction)

```text
CLI / DSL
    ↓
Application
    ↓
Domain / Model          ← 純粋な Ruby オブジェクト。AWS SDK 依存なし
    ↓
Compiler / Ports        ← CloudFormation 変換・Build。副作用なし
    ↓
AWS / Infrastructure Adapters ← AWS SDK を直接扱う唯一のレイヤー
```

## コンポーネント (Components)

### CLI
ユーザーの意図をパースし、設定をロードしてアプリケーションサービスを呼び出し、診断結果をフォーマットして出力します。CLIコンポーネント自体にAWSリソースの生成ロジックを含めてはなりません。

### DSL ファサード (DSL Facade)
型付きの宣言（モデル）を生成する軽量なRuby APIです。DSLメソッドはビルド処理を委譲するだけであり、CloudFormationのハッシュ構造を直接操作しません。

### ドメインモデル (Domain Model)
Application、Function、Layer、Schedule、FileSystemMount、AccessPointReference、Permission、Artifact、StagePolicyなどの不変（または事実上不変の）オブジェクト群です。AWS SDK には依存せず、純粋な Ruby オブジェクト（PORO）として設計します。

### リソースグラフ (Resource Graph)
シンボリックな参照を解決し、依存関係の循環を検出し、ビルド順序を決定し、CloudFormationコンパイラに対して依存関係のエッジ情報を提供します。

### ビルドサブシステム (Build Subsystem)
関数のZIPおよびLayerのZIPファイルを作成します。Bundlerを実行し、コンテナを使用したネイティブビルドを処理し、ファイルの包含/除外ルールを適用し、コンテンツハッシュを計算します。決定論的なアーカイブ生成により、同一入力から常に同一の ZIP を生成します。

### バリデータ (Validators)
アプリケーションモデルに対して動作する、純粋な検証チェック機能です。AWSのリソース状態に依存する診断ロジックは、インスペクターサブシステムとして分離されます。

### 診断 (Diagnostics)
バリデーションエラーや検査結果を構造化された Diagnostic オブジェクトとして収集し、CLIへ出力します。恒久的なエラーコード（`VLT-<category>-<id>` 形式）によって診断結果を識別します。

### AWS インスペクター (AWS Inspectors)
`efs verify`、アカウントチェック、既存リソースの検証、および変更セットの検証で使用される、AWS SDKの読み取り専用クライアント群です。副作用境界の外側に配置されます。

### CloudFormation コンパイラ (CloudFormation Compiler)
型付きのドメインリソースを標準のCloudFormationにマッピングします。正規化されたモデルとアーティファクトのハッシュ値が同一である限り、コンパイル結果は常に決定的（再現可能）でなければなりません。

### デプロイ実行器 (Deployment Executor)
アーティファクトをアップロードし、変更セット（Change Set）を作成または更新し、リソースの準備完了を待機し、必要に応じて承認を要求し、変更セットを実行します。副作用境界の外側に配置されます。

## 推奨されるGem構成 (Suggested Gem Structure)

```text
lib/veltrunode/
  cli/           # CLI コマンドルーター（Side Effect 境界）
  dsl/           # Veltrunodefile DSL 評価
  model/         # Internal Model（Pure Ruby PORO）
  graph/         # Dependency Resolution
  validation/    # Validators（Pure、AWS SDK 不使用）
  build/         # Build Subsystem（Artifact Generation）
  compiler/      # CloudFormation Compiler
  diagnostics/   # Diagnostics 収集・構造化
  aws/           # AWS Adapter（Side Effect 境界。AWS SDK 直接利用可）
  deploy/        # Deployment Executor（Side Effect 境界）
```

最初は単一のGemとして開始し、独立したリリースサイクルが正当化される場合にのみ分割を検討してください。
