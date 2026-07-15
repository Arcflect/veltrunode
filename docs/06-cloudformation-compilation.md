# CloudFormation コンパイル (CloudFormation Compilation)

CloudFormationは本ツールのプライマリなデプロイ形式です。コンパイラは、独自の状態で表現された中間表現ではなく、標準のAWSリソースを出力します。

## 出力されるファイル群 (Outputs)

- `build/template.yml`: デプロイ可能なCloudFormationテンプレート。
- `build/manifest.json`: 正規化されたアプリケーションモデル、アーティファクトのハッシュ値、IAMの展開結果、およびコンパイラのバージョン情報。
- `build/artifacts/functions/*.zip`: 関数のデプロイパッケージ。
- `build/artifacts/layers/*.zip`: Layerのデプロイパッケージ。

## 決定性 (Determinism)

論理ID（Logical ID）は、ドキュメント化された安定した変換ルールを使用して、シンボリック名から生成されます。マップのキーはソートされ、コンテンツベースのハッシュ値出力からタイムスタンプは除外されます。また、ZIPファイルのエントリ内のタイムスタンプは可能な限り正規化されます。

## 変更セット (Change Sets)

`plan` コマンドはCloudFormationの変更セット（Change Set）を使用するため、ユーザーは実行前に変更内容を確認できます。リソースの置換（Replacement）や削除（Deletion）の影響は強調して表示されます。なお、計画（plan）がすべての実行時リスクを排除できると主張することはありません。

## 既存のインフラストラクチャ (Existing Infrastructure)

参照先には、リテラルARN、CloudFormationパラメータ、スタック出力（Export）、またはステージごとの値を指定できます。ユーザーが明確に本ツール側にリソース管理を要求しない限り、既存のEFS、VPC、サブネット、セキュリティグループ、キュー、およびS3バケットをCloudFormationスタック内にインポート（管理対象化）すべきではありません。
