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
ローカルPC上（コンテナ環境等）でLambda関数を疑似的に実行し、動作テストやデバッグを行います。`--event` オプションでモックイベントのJSONファイルを渡すことができます。

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
- 2: 無効な入力
- 3: バリデーション失敗
- 4: AWS認証失敗 / アカウント情報の不整合
- 5: ビルド失敗
- 6: プラン（計画）失敗
- 7: デプロイ失敗
- 8: ポリシー違反による拒否

## 出力形式

通常は人間に読みやすいテキスト形式（標準出力）で出力されます。`--format json` オプションを指定すると、CI/CDツールに適した構造化JSON形式で出力されます。機密情報（シークレット）は自動的にマスクされます。
