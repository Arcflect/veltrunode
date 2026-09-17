# セキュリティと IAM (Security and IAM)

## 設計原則 (Principles)

- デフォルトで最小特権（least privilege）を適用します。
- 具体的な ARN を生成できる箇所では、リソース指定へのワイルドカード（`*`）の使用を避けます。
- Lambda 実行ロールと Scheduler 呼び出しロールを明確に分離します。
- 付与されるすべての権限は、plan（計画）およびマニフェストファイルにて視認可能な状態にします。
- 本番ステージのポリシーでは、アクションに対するワイルドカードの指定、パブリックストレージの使用、ログ保持期間の設定漏れ、および DLQ の未設定に対して拒否（エラー）を設定できます。

## ステージポリシー (Stage Policies)

ステージ（`production`, `staging` 等）に応じて厳格なセキュリティ要件を強制するための `StagePolicy` を定義できます。バリデーションフェーズにおいてポリシー違反が検出された場合、エラー Diagnostic（`VLT-IAM-001`, `VLT-IAM-002`, `VLT-SCHED-002`, `VLT-LOG-001` 等）が出力され、CLI は終了コード `8`（`EXIT_POLICY_VIOLATION`）で停止します。

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

Veltrunode は、標準の AWS SDK 資格情報チェーン（Credential Chain）を使用します。ツール自体が認証情報を収集したり、プロキシしたりすることはありません。リソースの変更操作（`deploy` 等）を行う前に、呼び出し元の AWS アカウントおよびリージョンが正しいかを事前検証（`AccountRegionGuard`）します。

### デプロイ前ガード（AWS アカウントおよびリージョン整合性チェック）

誤ったAWS環境への意図しないデプロイを防ぐため、`veltrunode deploy` 実行直前に以下の検証を実施します。

1. **AWS 認証と呼び出し元アカウントの確認**:
   - `STS:GetCallerIdentity` を実行し、現在有効な AWS アカウント ID を取得します。
   - 認証失敗またはクライアント初期化不可の場合はエラー Diagnostic（`VLT-AWS-AUTH-001`）を出力し、デプロイを中止します。
2. **アカウント制約（`account` / `account_constraint`）との照合**:
   - `Veltrunodefile` にアカウント制約が明示されている場合、取得したアカウント ID と厳密に一致するかを照合します。不一致の場合はエラー Diagnostic（`VLT-AWS-ACCOUNT-001`）を出力し、デプロイを中止します。
   - アカウント制約が未設定の場合は、警告 Diagnostic（`VLT-AWS-ACCOUNT-002`）を出力して注意を促した上でデプロイを継続します。
3. **リージョン設定（`region`）との照合**:
   - 明示的に設定された AWS SDK / 環境変数（`AWS_REGION`, `AWS_DEFAULT_REGION`, `Aws.config[:region]`）と、`Veltrunodefile` に定義された `application.region` を照合します。
   - 不一致が検出された場合はエラー Diagnostic（`VLT-AWS-REGION-001`）を出力し、デプロイを中止します。
4. **終了コード**:
   - アカウント不一致、リージョン不一致、認証失敗等のエラーが検出された場合、CLI は終了コード `4`（`EXIT_AWS_AUTH_FAILED`）で安全に停止します。

## サプライチェーン (Supply Chain)

- 署名付きのリリースは、ロードマップ項目として定義されています。
- 依存する Gem 等のパッケージはロックされ、レビュー済みの自動化プロセスを通じてアップデートされます。
- リリースビルドは CI環境 で実行されます。
- SBOM（ソフトウェア部品構成表）の生成を計画しています。
- セキュリティ報告に関しては、[SECURITY.md](../SECURITY.md) に規定されている手順に従います。
- 依存関係と GitHub Actions の更新は、[.github/dependabot.yml](../.github/dependabot.yml) を用いて自動化します。
