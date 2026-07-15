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
