# EventBridge Scheduler 設計 (EventBridge Scheduler Design)

## サポートされるスケジュールタイプ

- 定期的な cron 式 (recurring cron expressions)
- 定期的な rate 式 (recurring rate expressions)
- 一回限りの `at` 式 (one-time `at` expressions)
- IANA タイムゾーン
- 有効（enabled）/ 無効（disabled）状態
- 柔軟な実行ウィンドウ（flexible time window）
- 再試行回数および最大イベント受信期間（maximum event age）
- SQS デッドレターキュー（DLQ）
- 定数 JSON インプット

## 検証項目 (Validation)

- スケジュール式と指定されたタイプが一致していること。
- タイムゾーンが認識可能なものであること。
- ターゲットとなる関数が存在すること。
- インプットが有効な JSON にシリアライズ可能であり、かつサービスの制限範囲内であること。
- 再試行の値がサポートされている範囲内であること。
- DLQがSQSであり、互換性のある権限セットが定義されていること。
- ステージポリシー（`require_dlq`）により、本番スケジュール等でDLQの指定が必須化されている場合は未設定時にエラー（`VLT-SCHED-002`）を出力すること。

## 実行予定プレビュー (Preview)

プレビューエンジンは、AWS側の状態を変更することなく、今後の実行予定日時を計算します。夏時間（DST）の遷移は明示的に表示されます。プレビューの出力はあくまで参考情報であり、最終的な実行スケジュールを保証するものはAWS側となります。

## IAM 権限設計

Schedulerは、デフォルトで専用の呼び出しロール（invocation role）を使用します。このロールの権限は、ターゲットのLambda関数のARN呼び出しのみに制限されます。共有ロールを使用することも可能ですが、セキュリティの観点から非推奨です。

---

## EventBridge ルールとカスタムイベントバストリガー (EventBridge Rule & Custom Event Bus)

定期実行の Scheduler だけでなく、デフォルトまたはカスタムイベントバスに送信されるドメインイベントをイベントパターン（JSON マッチング）でフィルタリングし、Lambda 関数を起動するトリガーを `rule`（または `event_source rule:`）DSL で定義できます。

### DSL 記述例

```ruby
function :order_handler, rule: {
  bus: "custom-orders-bus",
  pattern: {
    source: ["myapp.orders"],
    "detail-type": ["OrderCreated", "OrderCompleted"]
  }
} do
  handler "orders.handler"
end

function :billing_handler do
  handler "billing.handler"
  rule bus: ref(:domain_bus),
       pattern: {
         source: ["myapp.billing"],
         "detail-type": ["InvoiceIssued"],
         detail: { status: ["OVERDUE"] }
       },
       state: :disabled
end
```

### サポートされる設定項目

- `bus`（エイリアス: `event_bus`, `event_bus_name`）: イベントバス名、ARN、または `ref(:bus_param)` 参照。省略時は `default` イベントバスが使用されます。
- `pattern`（エイリアス: `event_pattern`, 必須）: `source` や `'detail-type'`、`detail` 等の JSON イベントパターンハッシュ。
- `state`: `:enabled`（デフォルト: `'ENABLED'`）または `:disabled`（ルール無効化: `'DISABLED'`）。
- `description`: ルールの説明文（省略可能）。
- `input`: ターゲットへ渡す定数 JSON インプット（省略可能）。

### CloudFormation コンパイル結果

- **`AWS::Events::Rule`** (`<Function>EventRule` または `<Function><RuleIdentifier>EventRule`):
  - `EventPattern`: 指定されたイベントパターンハッシュ
  - `EventBusName`: `bus` 指定時のみ出力（`ref(:domain_bus)` 指定時は `Parameters` に自動登録のうえ `{ "Ref" => "DomainBus" }` を設定）
  - `State`: `"ENABLED"` または `"DISABLED"`
  - `Targets`: `[{ "Arn" => { "Fn::GetAtt" => ["<Function>", "Arn"] }, "Id" => "<Function>Target" }]`
- **`AWS::Lambda::Permission`** (`<Function>EventsPermission` または `<Function><RuleIdentifier>EventsPermission`):
  - `Action`: `"lambda:InvokeFunction"`
  - `FunctionName`: `{ "Fn::GetAtt" => ["<Function>", "Arn"] }`
  - `Principal`: `"events.amazonaws.com"`
  - `SourceArn`: `{ "Fn::GetAtt" => ["<RuleLogicalId>", "Arn"] }`
