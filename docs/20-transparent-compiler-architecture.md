# Transparent Compiler Architecture

> **関連ADR**: [ADR-0002](adr/0002-transparent-compiler-architecture.md)

## Veltrunode の位置付け

Veltrunode は **AWS Lambda を中心としたサーバーレスデプロイツール**です。

Transparent Compiler Architecture はプロダクトカテゴリを変更するものではありません。Veltrunode をコンパイラ製品として定義するのではなく、Lambda デプロイツール内部の処理を明確な変換パイプラインとして設計するための **内部開発モデル** として使用します。

## 全体パイプライン (Full Pipeline)

```text
┌─────────────────────────────────────────────────────────────────┐
│  Veltrunodefile                                                  │
│  （ユーザー定義）                                               │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  DSL Layer                                                       │
│  • Veltrunodefile を評価し宣言情報を収集する                    │
│  • AWS SDK・CloudFormation ハッシュには触れない                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Normalization                                                   │
│  • DSL 出力を型付き内部モデルへ変換する                         │
│  • デフォルト値の適用・型強制・フォーマット正規化              │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Internal Model                                                  │
│  Application / Function / Layer / Schedule / EfsMount 等        │
│  Pure Ruby PORO — AWS SDK 依存なし                               │
└──────┬────────────┬────────────────┬──────────────────┬─────────┘
       │            │                │                  │
       ▼            ▼                ▼                  ▼
  Validation  Dependency         Diagnostics        Policy
  （純粋な    Resolution         （診断結果の        （ステージ
   検証）     （参照解決・        収集と             ポリシー
              循環検出）         構造化）            チェック）
       │            │                │                  │
       └────────────┴────────────────┴──────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Artifact / Infrastructure Compiler                              │
│  • CloudFormation Compiler（型付きモデル → template.yml）       │
│  • Build Subsystem（関数 ZIP / Layer ZIP の決定論的生成）       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Deployment Plan                                                  │
│  • CloudFormation Change Set の作成                              │
│  • デプロイ前の差分確認（manifest, plan 表示）                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS Deployment  ← Side Effect 境界                              │
│  • S3 アップロード                                               │
│  • CloudFormation Change Set 実行                                │
│  • 完了待機・承認処理                                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
                          AWS
```

## Core / Side Effect の境界定義

```text
┌──────────────── Core（副作用なし） ────────────────┐
│  DSL Layer                                         │
│  Normalization                                     │
│  Internal Model                                    │
│  Validation                                        │
│  Dependency Resolution                             │
│  CloudFormation Compiler                           │
│  Build Subsystem（ファイル読み書きを除くロジック）  │
└────────────────────────────────────────────────────┘

┌──────────────── Side Effects（副作用あり） ─────────┐
│  AWS SDK                                            │
│  CloudFormation API                                 │
│  S3 API                                             │
│  Docker（ネイティブビルド）                         │
│  File System（ZIP 生成・アーティファクト書き込み）  │
│  Network                                            │
└─────────────────────────────────────────────────────┘
```

副作用を持つ処理は `aws/`, `deploy/`, `build/` の外側レイヤーに集約し、内部モデルや Validation に無秩序に侵入させません。

## モジュール間の依存方向 (Dependency Direction)

```text
CLI / DSL
    ↓ （ユーザー入力を受け取り、Application サービスを呼び出す）
Application
    ↓ （ユースケースを調整する）
Domain / Model              ← 純粋な Ruby オブジェクト。AWS SDK 依存なし
    ↓ （モデルを変換する）
Compiler / Ports            ← CloudFormation 変換・Build。決定論的・副作用なし
    ↓ （具体的な外部サービスを呼ぶ）
AWS / Infrastructure Adapters  ← AWS SDK を直接扱う唯一のレイヤー
```

Core 側から具体的な AWS SDK 実装へは直接依存しません。必要に応じて Adapter（`aws/inspectors/`, `deploy/` など）を介します。

## AWS SDK を直接扱ってよいレイヤー

| レイヤー / モジュール | AWS SDK 直接利用 | 理由 |
|---|---|---|
| `aws/` (Inspectors) | **可** | 読み取り専用の AWS リソース検証。副作用境界として明示 |
| `deploy/` (Executor) | **可** | デプロイ実行。副作用境界として明示 |
| `model/` | **不可** | Pure PORO として保つ |
| `validation/` | **不可** | 静的検証のみ。AWS 状態に依存しない |
| `compiler/` | **不可** | 決定論的な変換のみ |
| `build/` (コアロジック) | **不可** | アーカイブ生成ロジックは純粋に保つ |
| `diagnostics/` | **不可** | 診断結果の構造化のみ |

## Internal Model の責務

Internal Model（`lib/veltrunode/model/`）は変換パイプラインの中核です。

- **Pure Ruby PORO** として設計し、AWS SDK・CloudFormation に一切依存しない
- DSL やユーザー入力を、Validation・Resolution・Compilation が処理しやすいクリーンな型付きオブジェクトへ変換する
- **不変（イミュータブル）** を原則とし、各フェーズが前フェーズのモデルを破壊的に変更しない
- `Application`, `Function`, `Layer`, `Schedule`, `EfsMount`, `Permission` などの Veltrunode 自身の概念をモデルとして扱う（CloudFormation Resource そのものではない）

## Compiler の責務

Compiler（`lib/veltrunode/compiler/`）は Internal Model を AWS デプロイ可能な成果物へ変換します。

- **決定論的**: 正規化済みモデルとアーティファクトハッシュが同一であれば、常に同一の CloudFormation テンプレートを生成する
- **副作用なし**: AWS API の呼び出しを行わない。生成物はメモリ内のデータ構造として保持し、書き込みは外側の境界が担う
- **型付きマッピング**: `Function → AWS::Lambda::Function`, `Layer → AWS::Lambda::LayerVersion` など、ドメインモデルから CloudFormation リソース型への変換を明確に定義する

## Diagnostics / Preflight Check の位置付け

### Diagnostics（診断）
- `lib/veltrunode/diagnostics/` に配置
- Validation・Compiler・Build などの各フェーズが検出した問題を **`Diagnostic` オブジェクト**として収集する
- 恒久的なエラーコード（`VLT-<category>-<id>` 形式）で識別し、CLI が構造化された診断レポートとして出力する
- **AWS API には依存しない**

### Preflight Check（プリフライトチェック）
- `aws/inspectors/` に配置
- AWS API を呼ばなければ判定できない問題（EFS アクセスポイントの存在確認、AWS アカウント一致チェックなど）を検証する
- **デプロイ前**に実行するが、**明示的に副作用境界（Side Effect Boundary）として扱い**、Validation とは分離する
- 例: `efs verify`, アカウントガード, 変更セット検証

## 既存コードとの照合（Definition of Done チェックリスト）

Issue #133 の Definition of Done は以下の通り達成されています。

| 項目 | 状態 | 参照先 |
|---|---|---|
| Transparent Compiler Architecture の位置付けを文書化 | ✅ | 本文書 + ADR-0002 |
| Veltrunode が Lambda デプロイツールであることを明記 | ✅ | 本文書冒頭 + docs/00 |
| Definition / Model / Validation / Compilation / Deployment の責務定義 | ✅ | 本文書 + docs/02 |
| Core と Side Effect の境界定義 | ✅ | 本文書「境界定義」節 |
| モジュール間の依存方向の定義 | ✅ | 本文書「依存方向」節 |
| AWS SDK へ直接依存してよいレイヤーの定義 | ✅ | 本文書「AWS SDK を直接扱ってよいレイヤー」節 |
| Internal Model の責務定義 | ✅ | 本文書「Internal Model の責務」節 |
| Compiler の責務定義 | ✅ | 本文書「Compiler の責務」節 |
| Diagnostics / Preflight Check の位置付け定義 | ✅ | 本文書「Diagnostics / Preflight Check」節 |
| 既存コードを新しい設計原則と照合 | ✅ | 各モジュールへの TCA 責務コメント追加 |
| 必要なリファクタリングの実行 | ✅ | 各モジュールへの TCA 責務コメント追加 |
