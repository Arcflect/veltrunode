# 開発ガイド (Development Guide)

本ドキュメントでは、Veltrunodeのローカル開発環境のセットアップ手順、ディレクトリ構造、コマンドの実行方法、およびテストの実行方法について説明します。

## 前提条件 (Prerequisites)

- **Ruby**: 3.0 以上（推奨: 3.2以上）
- **Bundler**: インストール済みであること
- **Python / Node.js**: ローカルシミュレータのテスト・実行を行う場合は、ローカルPCにそれぞれの実行環境が必要です。

## ローカル環境のセットアップ (Setup)

システムディレクトリ（`/var/lib/gems` など）への書き込み制限を回避するため、依存するGemパッケージをプロジェクトローカル（`vendor/bundle`）にインストールします。

1. **Bundlerのローカルパス構成設定**:
   ```bash
   bundle config set --local path 'vendor/bundle'
   ```
2. **依存パッケージのインストール**:
   ```bash
   bundle install
   ```

*注意: 開発環境に `ruby-dev` (または `ruby-devel` 等のヘッダーファイル) がインストールされていない場合、ネイティブ拡張機能を持つ一部のGem（RuboCopなど）のインストールがエラーになることがあります。その場合は必要に応じてシステム側に `ruby-dev` をインストールするか、GemfileからそれらのGemを除外してインストールしてください。*

## ディレクトリ構造 (Directory Structure)

```text
veltrunode/
  ├── exe/
  │   └── veltrunode          # CLI実行可能スクリプト（エントリーポイント）
  ├── lib/
  │   ├── veltrunode/
  │   │   ├── cli.rb          # CLIコマンドルーター（Thor）
  │   │   ├── dsl.rb          # Veltrunodefile用のDSL評価コンテキスト
  │   │   ├── generator.rb    # プロジェクト初期化（init）のコード生成処理
  │   │   ├── model.rb        # アプリケーション、関数等のドメインモデル定義
  │   │   ├── runner.rb       # 各言語（Ruby/Python/Node.js）のローカル実行処理
  │   │   └── version.rb      # Gemのバージョン定義
  │   └── veltrunode.rb       # 主要モジュール定義とエントリーポイント
  ├── spec/
  │   ├── dsl_spec.rb         # DSLパース処理のテスト
  │   ├── runner_spec.rb      # ローカル実行シミュレーションのテスト
  │   └── spec_helper.rb      # RSpec共通設定
  ├── DEVELOPMENT.md          # 本開発手順書
  ├── Gemfile                 # 開発用依存関係
  └── veltrunode.gemspec      # Gemスペックの定義
```

## CLI コマンドのローカル実行 (Running CLI)

開発中のツールをローカルで実行するには、`bundle exec` を介して `veltrunode` を呼び出します。

### 1. プロジェクトの初期化
```bash
bundle exec veltrunode init
```
`Veltrunodefile` やサンプル関数（`functions/hello.rb` 等）がカレントディレクトリに生成されます。

### 2. 設定の検証
```bash
bundle exec veltrunode validate
```
`Veltrunodefile` の構文や定義の整合性をチェックします。

### 3. 関数のローカルシミュレート実行
```bash
bundle exec veltrunode invoke local <関数名>
```
例（イベントデータを渡す場合）:
```bash
bundle exec veltrunode invoke local hello --event path/to/event.json
```

## テストの実行方法 (Testing)

ユニットテストおよび統合テストには **RSpec** を使用します。

### テストの実行
```bash
bundle exec rspec
```

RSpecは `spec/` ディレクトリ配下のすべての `*_spec.rb` ファイルを検出して実行します。

### カバレッジ付きテストの実行

```bash
bundle exec rspec
```

`spec/spec_helper.rb` で SimpleCov を有効化しているため、実行後は `coverage/` ディレクトリに計測結果が出力されます。

## Lint の実行方法 (Linting)

静的解析には **RuboCop** を使用します。CI でも `bundle exec rubocop` を実行します。

### RuboCop の実行

```bash
bundle exec rubocop
```

Bundler を使わずにローカルのユーザー Gem 領域から RuboCop を実行したい場合は、補助スクリプトも利用できます。

```bash
bin/lint
```

## コード設計原則 (Code Design Principles)

Veltrunode の内部実装では **Transparent Compiler Architecture（TCA）** を開発モデルとして採用しています（[ADR-0002](docs/adr/0002-transparent-compiler-architecture.md)）。詳細は [docs/20-transparent-compiler-architecture.md](docs/20-transparent-compiler-architecture.md) を参照してください。

開発およびリファクタリングの際は、以下の 7 つの原則を意識してください。

### 1. Internal Model First
DSL や CLI の入力をそのまま AWS 処理へ渡さないでください。必ず Veltrunode 内部モデル（`Function`, `Layer`, `Schedule`, `EfsMount` など）へ変換してから後続処理を行います。
- **Good**: DSL が `Function` モデルを生成 → Compiler が `Function` を `AWS::Lambda::Function` へ変換
- **Bad**: DSL が直接 CloudFormation ハッシュを構築する

### 2. Separate Definition from Execution
「何を作るか」（`model/`, `compiler/`）と「実際に作る処理」（`aws/`, `deploy/`, `build/`）を分離してください。
- `Function` の定義（Definition）は AWS Lambda がそこに存在しなくても完全に記述できる状態にします。
- 実際の作成処理（Execution）は副作用境界のレイヤーが担います。

### 3. Deterministic Transformation
同じ入力からは常に同じ内部モデルおよびデプロイ成果物を生成してください。
- 変換処理に外部状態（時刻・乱数・外部 API のレスポンス）を混入させないでください。
- `DeterministicArchiver` のように、ZIP 生成においても byte-for-byte の再現性を保証します。

### 4. Explicit Side Effects（副作用の隔離）
AWS API・File System・Docker・Network などの副作用を明確な境界へ隔離してください。
- **純粋なコア** (`model/`, `validation/`, `compiler/`, `diagnostics/`): 外部と通信しない Pure Ruby ロジック。モックなしで高速にテストできます。
- **副作用境界** (`aws/`, `deploy/`, `build/` の IO 処理): インターフェースを明確にし、テスト時にモックできるように構成します。

### 5. Validation Before Deployment
可能な問題は AWS へデプロイする前に検出してください。
- AWS API を呼ばずに判定できるものはすべて `validation/` に配置します。
- AWS API を呼ばなければ判定できないもの（EFS 接続確認、アカウントガードなど）は `aws/inspectors/` に配置し、Preflight Check として明示的に分離します。

### 6. Inspectable Intermediate State
内部処理をブラックボックス化しないでください。
- 各フェーズの出力（正規化済みモデル・解決済みグラフ・生成テンプレート・ビルド成果物）を参照できる構造を保ちます。
- 将来的な `veltrunode inspect`, `veltrunode plan` コマンドの基盤となります。

### 7. Dependency Direction（依存方向の固定）
依存方向を以下に固定してください。上位レイヤーは下位レイヤーに依存しますが、下位レイヤーは上位レイヤーに依存しません。

```text
CLI / DSL
    ↓
Application
    ↓
Domain / Model  ← 純粋な Ruby オブジェクト。AWS SDK 依存なし
    ↓
Compiler / Ports
    ↓
AWS / Infrastructure Adapters ← AWS SDK を直接扱う唯一のレイヤー
```

