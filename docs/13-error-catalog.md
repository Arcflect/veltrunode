# エラーおよび診断カタログ (Error and Diagnostic Catalog)

本ツールで使用される永続的なエラーコードは、`VLT-<分類>-<識別番号>` の形式を採用します。

## エラーコードの例 (Examples)

- **VLT-DSL-001**: 不明な DSL メソッド (unknown DSL method)
- **VLT-REF-001**: 未解決のシンボリック参照 (unresolved symbolic reference)
- **VLT-GRAPH-001**: 循環依存関係の検出 (dependency cycle)
- **VLT-BUILD-001**: ネイティブビルドの失敗 (native build failed)
- **VLT-BUILD-SECRET-WARN**: 機密情報ファイルの検出警告 (possible secret file or high-entropy string detected)
- **VLT-LAYER-001**: 互換性のないアーキテクチャ (incompatible architecture)
- **VLT-SCHED-001**: 無効なスケジュール式 (invalid schedule expression)
- **VLT-SCHED-002**: ステージポリシーによるDLQ未設定の拒否 (missing DLQ required by stage policy)
- **VLT-LOG-001**: ステージポリシーによるログ保持期間未設定の拒否 (missing log retention required by stage policy)
- **VLT-EFS-001**: EFSアクセスポイントが見つからない (access point not found)
- **VLT-EFS-2049-INGRESS**: NFS インバウンド設定不足 (missing NFS ingress)
- **VLT-EFS-2049-EGRESS**: NFS アウトバウンド設定不足 (missing NFS egress)
- **VLT-AWS-AUTH-001**: AWS認証またはSTS接続の失敗 (AWS authentication / STS connection failed)
- **VLT-AWS-ACCOUNT-001**: AWSアカウント情報の不整合 (account mismatch)
- **VLT-AWS-ACCOUNT-002**: 本番ステージまたはデプロイ時のAWSアカウント制約未設定の警告 (missing account constraint in production stage or deployment)
- **VLT-AWS-REGION-001**: AWSリージョン設定の不整合 (region mismatch)
- **VLT-IAM-001**: ステージポリシーによるワイルドカード指定の拒否 (wildcard denied by stage policy)
- **VLT-IAM-002**: ステージポリシーによるパブリックストレージ設定の拒否 (public storage denied by stage policy)
- **VLT-CFN-001**: 変更セット（Change Set）の作成失敗 (change set creation failed)
- **VLT-CFN-ROLLBACK**: スタック更新失敗・ロールバックの検出 (stack update failed / rollback triggered)
- **VLT-CFN-ROLLBACK-IAM**: IAM権限不足によるロールバック (rollback caused by IAM permission denied)
- **VLT-CFN-ROLLBACK-LIMIT**: リソース制限またはクォータ超過によるロールバック (rollback caused by resource limit or quota exceeded)
- **VLT-CFN-ROLLBACK-EXISTS**: リソース重複・競合によるロールバック (rollback caused by resource already exists / conflict)
- **VLT-CFN-ROLLBACK-CONFIG**: 無効な設定・パラメータによるロールバック (rollback caused by invalid resource configuration)

## 診断情報の構造

出力される各診断情報には、エラーコード、重要度（Severity）、概要、エビデンス（検証データ）、影響を受ける定義ファイルのパス、推奨されるアクション、および任意の AWS リソース識別子（ARNなど）が含まれます。エラーメッセージのテキスト表現は本プロジェクト独自のものであり、他のいかなるフレームワークの表現や言い回しも模倣してはなりません。
