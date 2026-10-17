# [ADR-0003] 管理された CloudFormation パッチ機能 (cloudformation_patch エスケープハッチ) の設計方針

* **ステータス (Status)**: 承認 (Accepted)（設計方針の確定、実装はPhase 1以降に延期）
* **作成日 (Date)**: 2026-10-17
* **起票者/著者 (Authors)**: @hirontan
* **関連Issue/PR (Related Issue/PR)**: #63

## コンテキスト (Context)

Veltrunode は AWS Lambda を中心としたサーバーレスデプロイツールとして、宣言的な Ruby DSL から決定論的かつ高品質な CloudFormation テンプレート（Lambda、Layer、EFS、EventBridge Scheduler、IAM、LogGroup 等）を自動生成します（[ADR-0001](0001-architecture-design-principles.md)、[ADR-0002](0002-transparent-compiler-architecture.md)）。

しかし、AWS CloudFormation が提供するリソースプロパティや機能は頻繁に拡張され、また個別の組織・案件固有のインフラ要件も多様です。Veltrunode のコア DSL が抽象化・標準サポートしていないプロパティを緊急に設定したい場合や、組織固有のコンプライアンス属性を付与したい場合に備え、**エスケープハッチ（Escape Hatch）** の提供が求められます（[docs/04-dsl-specification.md](../04-dsl-specification.md)）。

一方で、従来の多くのツールに見られる「テンプレート全体の raw YAML/JSON による無制限な上書き・全置換」を許容すると、以下の深刻な問題が発生します：

1. **決定論的ビルドとトレーサビリティの破壊**: Veltrunode が保証する決定論的コンパイルおよび `manifest.json` の整合性が損なわれる。
2. **安全な変更セット（Change Set）の無力化**: 意図しないリソース置換（Replacement）や破壊的削除（Deletion）を検知できなくなる。
3. **セキュリティガバナンスの迂回**: 本番ポリシーパックや IAM 最小権限原則をパッチにより無効化できてしまうリスク。
4. **Transparent Compiler Architecture (TCA) との不整合**: パイプラインを無視したバイパスが発生する。

このため、Veltrunode では安全性を損なわない **管理された部分パッチ機能（`cloudformation_patch`）** の設計方針を策定する必要があります。

---

## 決定事項 (Decision)

Veltrunode におけるエスケープハッチとして、以下の設計方針に基づく **管理された `cloudformation_patch` 機能** を採用します。なお、本機能の実装は **Phase 1 以降（Phase 2/3/4 の適切なマイルストーン）に段階的に実施** します。

### 1. エスケープハッチの基本原則
- **リソース単位のスコープ限定**: テンプレート全体の任意置換は一切許可せず、Veltrunode が生成した既存の論理リソース（Logical Resource ID）を対象とした部分変更（パッチ）のみを許可する。
- **スキーマ検証の必須通過**: パッチ適用後のリソース定義は、AWS 公式の CloudFormation スキーマ検証を必ず通過しなければならない。
- **セキュリティポリシーの不可侵**: パッチ適用によってセキュリティポリシーパックや保護制約を無効化・迂回することはできない。
- **監査可能性 (Auditability)**: すべてのパッチ操作は `manifest.json` に記録され、`plan` 実行時の差分表示で明示される。

---

### 2. ユースケース (Use Cases)

`cloudformation_patch` が対象とする主なユースケースは以下の通りです：

1. **未サポートまたは最新の CloudFormation プロパティの補完**
   - 例: Lambda の `SnapStart`、`LoggingConfig`（詳細ログフォーマットやアプリケーションログレベル）、`RuntimeManagementConfig`、`EphemeralStorage` の特殊設定など、Veltrunode のコア DSL にまだネイティブメソッドが存在しない新機能の即時利用。
2. **組織標準のメタデータおよび共通タグの注入**
   - 例: 社内監査ツールが要求する `Metadata` 属性、特定のフォーマットのコスト配分タグ（`CostCenter`, `OwnerTeam` 等）の特定リソースへの追加。
3. **リソース属性（Resource Attributes）のカスタマイズ**
   - 例: `DeletionPolicy: Retain` や `UpdateReplacePolicy: Retain` の付与によるステートフルリソースの保護、明示的な `DependsOn` の微調整。
4. **既存ネットワーク・セキュリティ設定の微調整**
   - 例: 自動生成されたセキュリティグループへの特定の説明文の追記、特殊なインバウンドルールの微調整。

---

### 3. 設計案（既存論理リソースの部分変更 API）

#### (1) DSL 構文設計
`cloudformation_patch` は、ターゲットとなるリソースを明示してブロック内で変更操作を宣言します。シンボリック名指定および論理 ID 直接指定の両方をサポートします。

```ruby
Veltrunode.application "document-converter" do
  aws region: "ap-northeast-1"
  runtime ruby: "3.3"

  function :processor do
    handler "app.handler"
    memory 512
  end

  # パッチ定義: 既存の論理リソースをターゲットにする
  cloudformation_patch :processor do
    # 1. set: 指定パスの値を設定または上書き (Dot Notation)
    set "Properties.SnapStart", { "ApplyOn" => "PublishedVersions" }
    set "Properties.LoggingConfig.LogFormat", "JSON"
    set "Properties.LoggingConfig.ApplicationLogLevel", "INFO"

    # 2. merge: 既存のハッシュや配列と安全にマージ
    merge "Properties.Tags", [
      { "Key" => "CostCenter", "Value" => "Engineering-101" }
    ]

    # 3. add: リソース属性の追加
    set "DeletionPolicy", "Retain"
  end

  # 論理リソースIDを直接ターゲットにする記法も許容
  cloudformation_patch "ProcessorFunctionLogGroup" do
    set "Properties.KmsKeyId", ref(:log_kms_key)
  end
end
```

#### (2) 操作プリミティブ
パッチエンジンは以下のプリミティブな操作を提供します（RFC 6902 JSON Patch に着想を得た安全なサブセット）：

- `set(path, value)`: 指定パスに値を設定。既存の値があれば上書き。
- `add(path, value)`: 配列への要素追加、または未定義キーへの値追加。
- `merge(path, hash_or_array)`: 既存の構造体を壊さずにディープマージ。
- `remove(path)`: 不要なオプショナルプロパティの削除（必須プロパティの削除は後述の検証で拒否）。

#### (3) コンパイルパイプライン（TCA）における適用タイミング
パッチエンジンは、**Transparent Compiler Architecture (ADR-0002)** のパイプラインにおいて以下の順序で実行されます：

```text
┌────────────────────────────────────────────────────────┐
│  Artifact / Infrastructure Compiler                    │
│  （型付き内部モデルからベースの CloudFormation 構造を生成） │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│  Patch Engine (cloudformation_patch 適用フェーズ)       │
│  1. ターゲット論理IDの存在確認                          │
│  2. パッチ操作の順次適用                               │
│  3. 変更メタデータの記録                               │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│  Validation & Policy Verification (最終検証フェーズ)   │
│  1. CloudFormation スキーマ検証 (cfn-lint 準拠)        │
│  2. DAG 循環参照チェック (DependsOn)                  │
│  3. セキュリティポリシーパック検証 (IAM/ログ等)        │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│  Output Generation (template.yml & manifest.json)      │
└────────────────────────────────────────────────────────┘
```

ベーステンプレートの決定論的生成が完了した直後にパッチを適用し、その後に最終的なスキーマ検証・セキュリティ検証を実施することで、不正なパッチを確実に水際で捕捉します。

---

### 4. スキーマ検証の方針 (Schema Validation Strategy)

パッチが適用された後のテンプレートは、必ず以下の多層防御による検証を通過しなければなりません：

1. **論理リソース存在検証 (Target Existence Check)**:
   - パッチが指定したターゲット（シンボリック名または論理ID）が、ベーステンプレートの `Resources` 内に存在しない場合は `VLT-CFN-PATCH-NOT-FOUND` エラーを即座に発生させる。
   - タイポや削除されたリソースへのパッチ放置を防止する。
2. **AWS CloudFormation Resource Specification / スキーマ検証**:
   - パッチ適用後のリソース定義が、AWS 公式の Resource Specification（または cfn-lint スキーマ）に準拠しているかを検証する。
   - 不正なプロパティ名、許容されないデータ型（文字列・数値・真偽値の不一致）、未サポートの組み込み関数の使用を静的に検出する。
3. **リソース型不変チェック (Resource Type Immutability Check)**:
   - `Type` 属性（例: `AWS::Lambda::Function`）の書き換えは固く禁止する。
4. **DAG 循環依存関係検証 (Circular Dependency Check)**:
   - `DependsOn` や `Ref` / `Fn::GetAtt` をパッチした結果、循環参照（Cyclic Dependency）が発生していないかを依存グラフ（ResourceGraph）で検証する。

---

### 5. テンプレート全体の任意置き換えは不可とする制約 (Prohibition of Arbitrary Template Replacement)

本機能では **「テンプレート全体の任意置き換え（Raw Template Override）」は一切サポートしません**。

#### 制約とする理由:
1. **決定論的ビルドと整合性の保証**:
   - テンプレート全体を外部 YAML/JSON で丸ごと上書きできるようにすると、Veltrunode が計算したアーティファクトハッシュ（ZIP の SHA-256）や S3 キーとのリンクが断絶します。
2. **変更セット（Change Set）プレビューの信頼性維持**:
   - 管理外のリソース変更が混入すると、`veltrunode plan` による安全な差分表示や置換・削除警告が正確に機能しなくなります。
3. **ツール機能の安定性維持**:
   - `efs verify` による接続診断や、`veltrunode destroy`、ロールバック診断は、Veltrunode が管理するリソースメタデータに依存しています。任意のリソース構造を流し込むと、これらのツール機能が故障します。

#### 技術的な制約機構:
- DSL 上で `template_override` や `raw_template` といったルートレベルの置換メソッドは提供しない。
- `cloudformation_patch` のスコープは `Resources.<LogicalId>` の内部に限定され、`AWSTemplateFormatVersion` などのルートプロパティは変更できない。

---

### 6. セキュリティ上の考慮事項 (Security Considerations)

エスケープハッチがセキュリティホールとならないよう、以下の保護機構を組み込みます：

1. **ポリシーパック（Policy Pack）の強制再評価**:
   - パッチ適用後に `Model::StagePolicy` および `PolicyPack` の検証を必ず実行する。
   - 例えば、パッチによって `AWS::IAM::Role` にワイルドカード権限（`Action: "*"` や `Resource: "*"`）を追加しようとした場合、ステージポリシーの `deny_wildcard_actions: true` によりコンパイルが拒否される。
   - パッチによって `RetentionInDays` を削除したり未設定にしようとした場合、`require_log_retention: true` により拒否される。
2. **シークレット（秘密情報）の平文埋め込み防止**:
   - パッチ内で平文のシークレットがハードコードされていないかを検査する。
   - パラメータ参照（`Ref`）や AWS Secrets Manager / Systems Manager Parameter Store 参照（`resolve:secretsmanager:...`）を推奨し、テンプレート出力への平文秘密情報混入を防ぐ。
3. **差分と監査の可視化**:
   - パッチによる変更内容は `manifest.json` 内の専用セクション（例: `manifest.patches`）にターゲットと変更内容を明記する。
   - `veltrunode plan` 実行時に、パッチによって変更されたプロパティを通常のリソースと区別して明示（例: `[PATCHED]` バッジの表示）し、レビュー担当者がエスケープハッチの使用を容易に認知できるようにする。

---

### 7. 実装フェーズの計画

本機能の実装は **Phase 1（コンパイルとビルドの基本機能完成）以降に延期** します。

- **Phase 0 / 現フェーズ**: 本 ADR による設計方針の合意およびドキュメント化（仕様確定）。
- **Phase 1**: コア DSL、内部モデル、CloudFormation コンパイラ、決定論的ビルド基盤を安定化。
- **Phase 1 以降（Phase 2/3/4）**:
  - `PatchEngine` の実装および `cloudformation_patch` DSL の導入。
  - CloudFormation Resource Specification に基づくスキーマ検証器の統合。
  - `manifest.json` および `plan` 出力へのパッチ差分可視化の実装。

---

## 代替案 (Alternatives)

- **代替案 A: テンプレート全体の raw YAML/JSON による任意置換・オーバーライドを認める**
  - **不採用理由**: Veltrunode のコア価値である決定論的ビルド、マニフェスト整合性、Change Set 安全性、セキュリティポリシーパックの強制がすべて無力化されるため。
- **代替案 B: CloudFormation マクロ (Macros) やカスタムリソースによるデプロイ時パッチ**
  - **不採用理由**: デプロイ実行時に AWS 側で変換が行われるため、ローカルでの決定論的プレビュー（`plan`）や静的検証が不可能になり、デプロイ前に安全性を保証できないため。
- **代替案 C: エスケープハッチを一切提供せず、コア DSL の拡張のみで対応する**
  - **不採用理由**: AWS の頻繁な機能リリースに DSL のアップデートが追いつかない期間、ユーザーが Veltrunode を実務で使用できなくなる（ブロッカーになる）事態を避けるため。限定的かつ安全なエスケープハッチの存在は実運用上不可欠。

---

## 根拠 (Rationale)

- **クリーンルーム開発と独自アーキテクチャの堅持**: 他ツールの無秩序なオーバーライドモデルを模倣せず、Transparent Compiler Architecture（TCA）に適合する管理されたパッチモデルを独自定義することで、法的安全性と設計の純粋性を維持する（[docs/15-clean-room-and-ip-policy.md](../15-clean-room-and-ip-policy.md)）。
- **利便性と安全性の両立**: ユーザーに未サポートプロパティへのアクセス経路を提供しつつ、スキーマ検証・ポリシーパック再検証・リソース単位の限定によって安全性を完全にコントロールできる。

---

## 影響 (Consequences)

- **ポジティブな影響 (Positive)**:
  - AWS の新機能やニッチなプロパティに対しても、DSL のバージョンアップを待たずに即座に対応可能となる。
  - テンプレート全体の上書きを防ぐことで、ツールの運用安定性とセキュリティガバナンスが完全に保護される。
  - パッチ適用結果が透明に検証・監査可能となる。
- **ネガティブな影響・リスク (Negative / Risks)**:
  - 将来の実装において、CloudFormation Resource Specification スキーマの更新管理やパッチエンジンの実装コストが発生する。
  - パッチの多用によって DSL の意図したシンプルさが損なわれるリスクがあるため、公式ベストプラクティスとして「エスケープハッチは一時的な回避策とし、頻出パターンはコア DSL に昇格させる」運用ガイドが必要となる。
- **必要なアクション (Follow-up Actions)**:
  - [docs/04-dsl-specification.md](../04-dsl-specification.md) のエスケープハッチ節に本 ADR への参照リンクを追加する。
  - Phase 1 完了後の適切なマイルストーンにおいて、本 ADR の設計に基づく実装タスクを起票する。
