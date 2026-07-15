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
- ステージポリシーにより、本番スケジュールではDLQの指定を必須とできること。

## 実行予定プレビュー (Preview)

プレビューエンジンは、AWS側の状態を変更することなく、今後の実行予定日時を計算します。夏時間（DST）の遷移は明示的に表示されます。プレビューの出力はあくまで参考情報であり、最終的な実行スケジュールを保証するものはAWS側となります。

## IAM 権限設計

Schedulerは、デフォルトで専用の呼び出しロール（invocation role）を使用します。このロールの権限は、ターゲットのLambda関数のARN呼び出しのみに制限されます。共有ロールを使用することも可能ですが、セキュリティの観点から非推奨です。
