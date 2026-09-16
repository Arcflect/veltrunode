# CloudFormation コンパイル (CloudFormation Compilation)

CloudFormationは本ツールのプライマリなデプロイ形式です。コンパイラは、独自の状態で表現された中間表現ではなく、標準のAWSリソースを出力します。

## 出力されるファイル群 (Outputs)

- `build/template.yml`: デプロイ可能なCloudFormationテンプレート。
- `build/manifest.json`: 正規化されたアプリケーションモデル、アーティファクトのハッシュ値、IAMの展開結果、およびコンパイラのバージョン情報。
- `build/artifacts/functions/*.zip`: 関数のデプロイパッケージ。
- `build/artifacts/layers/*.zip`: Layerのデプロイパッケージ。

## 決定性 (Determinism)

論理ID（Logical ID）は、ドキュメント化された安定した変換ルールを使用して、シンボリック名から生成されます。マップのキーはソートされ、コンテンツベースのハッシュ値出力からタイムスタンプは除外されます。また、ZIPファイルのエントリ内のタイムスタンプは可能な限り正規化されます。

## 論理ID (Logical ID) の生成ルール

CloudFormation の論理ID（Logical ID）は、`Veltrunode::Compiler::LogicalId` モジュールにより、シンボリック名から決定論的かつ安定したルールで生成されます。ルールが変更されると CloudFormation リソースの置換（Replacement）が発生するため、変換規則の安定性が保証されています。

### 変換規則

1. **PascalCase 変換**:
   - シンボリック名（Symbol または String）を単語区切り文字（`_`, `-`, `.`, `/`, スペース等）で分割し、各単語の先頭を大文字にして連結します（例: `:runtime_gems` → `RuntimeGems`）。
2. **リソース型ごとのサフィックス付与**:
   - リソースの種類に応じたサフィックスを付与します。
   - シンボリック名が既に該当サフィックスで終わっている場合、二重付与は行われません（例: `convert_function` → `ConvertFunction`）。
3. **決定性と一意性**:
   - 同一のシンボリック名およびリソース型からは常に同一の論理IDが生成されます。
   - 同一シンボリック名であってもリソース型（Function, Layer, Schedule 等）ごとに異なる論理IDが生成され、名前空間の衝突を防止します。

### リソース種別と変換例

| リソース種別 | シンボリック名例 | 生成される論理ID | 説明 |
| :--- | :--- | :--- | :--- |
| **Function** | `:convert` | `ConvertFunction` | Lambda 関数 (`AWS::Lambda::Function`) |
| **Layer** | `:runtime_gems` | `RuntimeGemsLayer` | Lambda Layer 論理名 |
| **LayerVersion** | `:runtime_gems` | `RuntimeGemsLayerVersion` | Lambda Layer バージョン (`AWS::Lambda::LayerVersion`) |
| **Schedule** | `:nightly` | `NightlySchedule` | EventBridge スケジュール (`AWS::Scheduler::Schedule`) |
| **Queue** | `:nightly_dlq` | `NightlyDlqQueue` | SQS キュー (`AWS::SQS::Queue`) |
| **LogGroup** | `:convert` | `ConvertFunctionLogGroup` | CloudWatch ロググループ (`AWS::Logs::LogGroup`) |
| **IAM Role (Lambda)** | `:convert` | `ConvertFunctionRole` | Lambda 実行ロール (`AWS::IAM::Role`) |
| **IAM Role (Scheduler)** | `:nightly` | `NightlyScheduleRole` | Scheduler 呼び出しロール (`AWS::IAM::Role`) |

## 変更セット (Change Sets)

`plan` コマンドはCloudFormationの変更セット（Change Set）を使用するため、ユーザーは実行前に変更内容を確認できます。リソースの置換（Replacement）や削除（Deletion）の影響は強調して表示されます。なお、計画（plan）がすべての実行時リスクを排除できると主張することはありません。

## 既存のインフラストラクチャ (Existing Infrastructure)

参照先には、リテラルARN、CloudFormationパラメータ、スタック出力（Export）、またはステージごとの値を指定できます。ユーザーが明確に本ツール側にリソース管理を要求しない限り、既存のEFS、VPC、サブネット、セキュリティグループ、キュー、およびS3バケットをCloudFormationスタック内にインポート（管理対象化）すべきではありません。

## S3 アーティファクトのアップロードと参照更新 (S3 Artifact Upload & Reference Updating)

Lambda 関数のデプロイパッケージおよび Layer バージョンのデプロイパッケージは、`Veltrunode::AWS::S3Uploader` を通じて指定された S3 バケットへアップロードされます。

### S3 キー命名規則
アーティファクトの S3 キーは、決定論的なコンテンツハッシュを含めることで重複アップロードを防止し、バージョニングされた一貫性を保ちます。

形式:
`veltrunode/<app>/<stage>/<hash>/<name>.zip`

- `<app>`: アプリケーション名（`application.name`）
- `<stage>`: デプロイステージ（例: `production`, `dev`）
- `<hash>`: ビルド成果物のコンテンツハッシュ（SHA-256）
- `<name>`: 関数名（`function.logical_name`）または Layer 名（`layer.name`）

### 重複アップロードのスキップ (Deduplication)
アップロード前に `head_object` API を実行し、同一コンテンツハッシュのオブジェクトが S3 上に既に存在する場合は実際のファイル転送をスキップします。これにより、変更のないパッケージの不要な転送コストやレイテンシを排除します。

### テンプレート参照の更新
アーティファクトがアップロードされると、生成された CloudFormation テンプレート（`build/template.yml`）内のリソース定義が自動的に更新されます。

- **Lambda 関数 (`AWS::Lambda::Function`)**:
  `Properties.Code.S3Bucket` および `Properties.Code.S3Key` がアップロード先 S3 バケットおよび S3 キーで更新されます。
- **Lambda Layer (`AWS::Lambda::LayerVersion`)**:
  `Properties.Content.S3Bucket` および `Properties.Content.S3Key` がアップロード先 S3 バケットおよび S3 キーで更新されます。

### CLI での利用
ビルド時に `--bucket` オプションを指定することで、ビルド直後にアーティファクトのアップロードおよびテンプレート更新を自動実行できます。

```bash
veltrunode build --bucket my-deployment-bucket
```

また、`Veltrunodefile` の `aws` 設定ブロックで `artifact_bucket` を指定することも可能です。
```ruby
Veltrunode.application "my-app" do
  aws region: "ap-northeast-1", artifact_bucket: "my-deployment-bucket"
end
```
