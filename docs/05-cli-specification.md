# CLI 仕様 (CLI Specification)

## コマンド一覧

### `veltrunode init`
最小限の構成ファイル、Gemfile、Veltrunodefile、サンプルハンドラー、テスト、およびCIワークフローを含むスケルトンプロジェクトを作成します。

### `veltrunode validate`
構文、ドメインモデル、参照関係、パッケージング、ステージポリシー、および任意のAWS接続検証を実行します。AWSリソースを変更することはありません。

### `veltrunode build`
決定論的な関数およびLayerのZIPアーティファクトに加え、`build/template.yml` および `build/manifest.json` を生成します。

### `veltrunode plan`
必要に応じて一時的なアーティファクトをアップロードし、CloudFormationの変更セット（Change Set）を作成して、リソースの作成・更新・削除・置換の影響を表示します。この段階では変更セットは実行されません。

### `veltrunode deploy`
検証（validate）、ビルド（build）、計画（plan）を実行し、設定されたステージポリシーに従って明示的な承認を取得した後に、変更セットを実行します。

### `veltrunode invoke local NAME`
ローカルPC上（コンテナ環境等）でLambda関数を疑似的に実行し、動作テストやデバッグを行います。

- **オプション**:
  - `--event <file>`: モックイベントのJSONファイルパス（未指定時は空のオブジェクト `{}`）
  - `--format <text|json>`: 出力形式（デフォルト: `text`）
  - `--file <path>`: カスタム `Veltrunodefile` のパス
- **模擬されるランタイム環境変数**:
  - `AWS_LAMBDA_FUNCTION_NAME`: 関数論理名
  - `AWS_LAMBDA_FUNCTION_VERSION`: `$LATEST`
  - `AWS_LAMBDA_FUNCTION_MEMORY_SIZE`: 設定メモリサイズ（MB）
  - `AWS_REGION` / `AWS_DEFAULT_REGION`: 設定リージョン
  - `LAMBDA_TASK_ROOT`: プロジェクトソースディレクトリ
  - `_HANDLER`: ハンドラー文字列
  - `STAGE`: アプリケーションのステージ
  - `VELTRUNODE_APP`: アプリケーション名
  - および関数固有の `environment` 設定値（実行完了後に確実に元の環境変数へ復元）
- **模擬される Lambda Context オブジェクト**:
  - `aws_request_id` (UUID), `function_name`, `function_version`, `invoked_function_arn`, `memory_limit_in_mb`
  - `log_group_name`, `log_stream_name`, `deadline_ms`
  - `get_remaining_time_in_millis` / `remaining_time_in_millis`（残り実行時間ミリ秒）
- **タイムアウト制御**:
  - 関数の `timeout` 設定値（秒）に基づきローカル実行時間を監視し、超過時はタイムアウトエラーを通知します。
- **制限事項 (Limitations)**:
  - **EFSマウントのシミュレーション**: ローカル実行環境ではEFSマウントのシミュレーションはスキップされます（実行時に警告 `[WARN]` が出力されます）。

### `veltrunode destroy`
スタックを削除する前に、削除計画を作成してプレビューを表示します。保護対象ステージでの実行時には、意図的な確認入力を要求します。

### `veltrunode efs verify NAME`
アクセスポイント、VPC、マウントターゲット、ルート設定、セキュリティグループ、NFS（ポート2049）、IAM権限、マウントパス、および期待されるPOSIX属性をチェックします。

### `veltrunode layer inspect NAME`
ソースのハッシュ値、生成されたサイズ、互換性のあるランタイムおよびアーキテクチャ、発行履歴、および再利用の判定結果を表示します。

### `veltrunode schedule preview NAME --count 10`
設定されたタイムゾーンにおける、将来の実行予定時刻の一覧を表示します。

## 終了コード (Exit Codes)

- 0: 成功
- 2: 無効な入力（不正な引数、イベントファイル不在・不正JSON、タイムアウト、ハンドラー実行エラー等）
- 3: バリデーション失敗
- 4: AWS認証失敗 / アカウント情報の不整合
- 5: ビルド失敗
- 6: プラン（計画）失敗
- 7: デプロイ失敗
- 8: ポリシー違反による拒否

## 出力形式

通常は人間に読みやすいテキスト形式（標準出力）で出力されます。`--format json` オプションを指定すると、CI/CDツールに適した構造化JSON形式で出力されます。機密情報（シークレット）は自動的にマスクされます。
