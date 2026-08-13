# [ADR-0002] Transparent Compiler Architecture の内部開発モデルとしての採用

* **ステータス (Status)**: 承認 (Accepted)
* **作成日 (Date)**: 2026-08-13
* **起票者/著者 (Authors)**: @hirontan
* **関連Issue/PR (Related Issue/PR)**: #133

## コンテキスト (Context)

Veltrunode は Lambda を中心としたサーバーレスデプロイツールとして継続的に機能拡張されている。扱う対象領域は Lambda 関数・Lambda Layer・EventBridge Scheduler・EFS・IAM・VPC・ビルド成果物・CloudFormation デプロイ・診断など多岐にわたる。

機能追加が増加するにつれ、以下のような構造的な問題が生じやすくなる。

- DSL から AWS SDK を直接呼び出し、処理が単一のコードパスに集中する
- Validation と Deployment の責務が混在し、デプロイ前の問題検出が困難になる
- CloudFormation 生成ロジックが複数箇所に分散し、決定論的な変換を保証できなくなる
- Build 処理と Infrastructure 定義が密結合し、独立した変更・テストが困難になる
- AWS 固有処理が Domain Model に侵入し、ユニットテストにモックが必要になる

これらを防ぐため、Veltrunode 内部のデータフローと責務境界を明確に定義する必要がある。

## 決定事項 (Decision)

Veltrunode 内部の実装モデルとして **Transparent Compiler Architecture（透明なコンパイラ・アーキテクチャ）** を採用する。

これは Veltrunode をコンパイラ製品として位置付けるものではなく、Lambda デプロイツール内部の処理を以下の変換パイプラインとして設計するための **内部開発モデル** として使用する。

```text
Veltrunodefile
      │
      ▼
   DSL Layer
      │
      ▼
Normalization
      │
      ▼
Internal Model
      │
      ├── Validation
      │
      ├── Dependency Resolution
      │
      ├── Diagnostics
      │
      └── Policy
      │
      ▼
Artifact / Infrastructure Compiler
      │
      ▼
CloudFormation / Build Artifact
      │
      ▼
   Deployment
      │
      ▼
      AWS
```

### Core Development Principles

採用する 7 つの設計原則を以下に定義する。

**1. Internal Model First**
DSL や CLI の入力をそのまま AWS 処理へ渡さない。必ず Veltrunode 内部モデル（`Function`, `Layer`, `Schedule`, `EfsMount`, `Environment` など）へ変換してから後続処理を行う。

**2. Separate Definition from Execution**
「何を作るか」（Definition: Function, Layer, Schedule, EFS, IAM）と「実際に作る処理」（Execution: Build, Upload, CloudFormation, AWS API Deploy）を別の責務として分離する。

**3. Deterministic Transformation**
同じ入力からは可能な限り同じ内部モデルおよびデプロイ成果物を生成する。変換処理に外部状態や副作用を混入させない。

**4. Explicit Side Effects**
AWS API・File System・Docker・Network などの副作用を明確な境界へ隔離する。副作用を持つ処理（AWS SDK, CloudFormation, S3, Docker, File System, Network）が内部モデルや Validation へ無秩序に侵入しないようにする。

**5. Validation Before Deployment**
可能な問題は AWS へデプロイする前に検出する。AWS API を呼ばなければ判定できないものについては Diagnostics または Preflight Check として明示的に分離する。

**6. Inspectable Intermediate State**
内部で何が解釈されたのかを確認できる構造を維持する。将来的に `veltrunode inspect`, `veltrunode validate`, `veltrunode plan` などから正規化済み設定・解決済みリソース・生成 CloudFormation・ビルド成果物・デプロイ差分を確認できる構造を目指す。

**7. Dependency Direction**
依存方向を以下に固定する。

```text
CLI / DSL
    ↓
Application
    ↓
Domain / Model
    ↓
Compiler / Ports
    ↓
AWS / Infrastructure Adapters
```

Core 側から具体的な AWS SDK 実装へは直接依存しない。必要に応じて Adapter を介する。

### Supporting Architecture Patterns

単独の Transparent Compiler Architecture で全てを定義するのではなく、以下の既存パターンと組み合わせる。

- **Functional Core / Imperative Shell**: 内部モデル・Validation・Compilation を可能な限り純粋に保ち、AWS や File System などの副作用を外側へ配置する。
- **Hexagonal Architecture**: AWS SDK, CloudFormation, Docker, File System などを Adapter として扱い、Core との境界を明確にする。
- **Domain Modeling**: CloudFormation Resource としてではなく、Veltrunode 自身の概念（Function, Layer, Schedule, EfsMount, BuildArtifact, Deployment など）を内部モデルとして扱う。

## 代替案 (Alternatives)

- **代替案 A: 機能追加のたびにアドホックな設計を続ける**
  - **不採用理由**: 機能数の増大とともに DSL-AWS 間の直接結合が複数箇所に生じ、Validation・Deployment の責務混在、CloudFormation 生成の分散が不可避となる。テスタビリティと拡張性が著しく低下する。

- **代替案 B: 完全な DDD（ドメイン駆動設計）を全面導入する**
  - **不採用理由**: 不必要なインターフェース・抽象クラスの導入が増大し、Veltrunode のような規模感のツールにとって過剰な設計負荷となる。本 ADR ではドメインモデリングの考え方は取り入れつつ、DDD を厳密に適用することは目的としない。

- **代替案 C: Clean Architecture を形式的に全面導入する**
  - **不採用理由**: 目的はアーキテクチャパターンの形式的な適用ではなく、Veltrunode の保守性・テスト容易性・拡張性の向上である。必要な考え方のみを取り入れ、形式的な全面導入は行わない。

## 根拠 (Rationale)

- **保守性の向上**: 変換パイプラインの各フェーズが独立した責務を持つことで、個々のフェーズの変更が他フェーズへ与える影響を最小化できる。
- **テスト容易性の向上**: Internal Model・Validation・Compilation を純粋な Ruby ロジックとして保つことで、AWS SDK のモックなしに高速なユニットテストが可能になる。
- **拡張性の向上**: 新しいリソース種別（EventBridge, EFS, VPC など）を追加する際に、既存のパイプライン構造に従って追加するだけでよく、アドホックな設計判断が不要になる。
- **クリーンルームポリシーへの適合**: 独自概念として Transparent Compiler Architecture を命名・定義することで、既存フレームワークのアーキテクチャを模倣するリスクを回避する（[docs/15-clean-room-and-ip-policy.md](../15-clean-room-and-ip-policy.md)）。

## 影響 (Consequences)

- **ポジティブな影響 (Positive)**:
  - 新機能追加時の設計指針が明確になり、責務境界の逸脱を早期に検出できるようになる。
  - Validation と Deployment の分離により、デプロイ前の静的検証範囲が広がる。
  - Internal Model が純粋な Ruby オブジェクトとして保たれ、ユニットテストの実行速度と信頼性が向上する。
  - 将来的な `veltrunode inspect` / `veltrunode plan` コマンドの実装基盤が整う。

- **ネガティブな影響・リスク (Negative / Risks)**:
  - 原則に照らした設計レビューのコストが生じる。
  - 既存コードのうち原則と乖離している部分（AWS 固有処理の Domain Model への侵入など）についてはリファクタリングが必要になる。

- **必要なアクション (Follow-up Actions)**:
  - 詳細なアーキテクチャ解説文書（`docs/20-transparent-compiler-architecture.md`）を作成する。
  - `docs/02-architecture.md` を TCA 対応の 8 フェーズ構造に更新する。
  - 既存の各モジュール（`model`, `validation`, `build`, `compiler`, `diagnostics`, `aws`）に TCA における責務コメントを追加する。
  - 今後発生する大きな設計変更において、本方針に従って新規 ADR を作成・管理する。
