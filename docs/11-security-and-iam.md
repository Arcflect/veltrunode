# セキュリティと IAM (Security and IAM)

## 設計原則 (Principles)

- デフォルトで最小特権（least privilege）を適用します。
- 具体的な ARN を生成できる箇所では、リソース指定へのワイルドカード（`*`）の使用を避けます。
- Lambda 実行ロールと Scheduler 呼び出しロールを明確に分離します。
- 付与されるすべての権限は、plan（計画）およびマニフェストファイルにて視認可能な状態にします。
- 本番ステージのポリシーでは、アクションに対するワイルドカードの指定、パブリックストレージの使用、ログ保持期間の設定漏れ、および DLQ の未設定に対して拒否（エラー）を設定できます。

## ステージポリシー (Stage Policies)

ステージ（`production`, `staging` 等）に応じて厳格なセキュリティ要件を強制するための `StagePolicy` を定義できます。バリデーションフェーズにおいてポリシー違反が検出された場合、エラー Diagnostic（`VLT-IAM-001`, `VLT-SCHED-001`, `VLT-BUILD-001` 等）が出力され、CLI は終了コード `8`（`EXIT_POLICY_VIOLATION`）で停止します。

### ポリシールール一覧

| ルール名 | 設定型 | 説明 |
| :--- | :--- | :--- |
| `deny_wildcard_actions` | boolean | IAM アクションに対するワイルドカード（`*`, `:*`）の指定を拒否します |
| `require_dlq` | boolean | すべてのスケジュール定義に対して DLQ（デッドレターキュー）の指定を必須とします |
| `require_log_retention` | boolean | CloudWatch Logs のログ保持期間（`retention_days`）の設定を必須とします |
| `deny_public_storage` | boolean | S3 等のストレージ定義におけるパブリックアクセス設定を拒否します |

### DSL での設定例

```ruby
Veltrunode.application "my-secure-app" do
  stage "production"

  stage_policy :production do
    deny_wildcard_actions true
    require_dlq true
    require_log_retention true
    deny_public_storage true
  end
end
```

## ケーパビリティの展開 (Capability Expansion)

高水準の「ケーパビリティ」は、設定の利便性を高めるための宣言であり、背後で隠された独自の魔法ではありません。各ケーパビリティは、生成された出力ファイル内にドキュメント化されているバージョン管理されたマッピングルールに従って展開されます。必要に応じて、ユーザーは明示的な IAM アクションを直接指定することもできます。

## 認証情報 (Credentials)

Veltrunode は、標準の AWS SDK 資格情報チェーン（Credential Chain）を使用します。ツール自体が認証情報を収集したり、プロキシしたりすることはありません。リソースの変更操作を行う前に、呼び出し元の AWS アカウントおよびリージョンが正しいかを検証します。

## サプライチェーン (Supply Chain)

- 署名付きのリリースは、ロードマップ項目として定義されています。
- 依存する Gem 等のパッケージはロックされ、レビュー済みの自動化プロセスを通じてアップデートされます。
- リリースビルドは CI環境 で実行されます。
- SBOM（ソフトウェア部品構成表）の生成を計画しています。
- セキュリティ報告に関しては、[SECURITY.md](../SECURITY.md) に規定されている手順に従います。
- 依存関係と GitHub Actions の更新は、[.github/dependabot.yml](../.github/dependabot.yml) を用いて自動化します。
