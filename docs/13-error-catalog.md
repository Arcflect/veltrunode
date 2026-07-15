# エラーおよび診断カタログ (Error and Diagnostic Catalog)

本ツールで使用される永続的なエラーコードは、`VLT-<分類>-<識別番号>` の形式を採用します。

## エラーコードの例 (Examples)

- **VLT-DSL-001**: 不明な DSL メソッド (unknown DSL method)
- **VLT-REF-001**: 未解決のシンボリック参照 (unresolved symbolic reference)
- **VLT-GRAPH-001**: 循環依存関係の検出 (dependency cycle)
- **VLT-BUILD-001**: ネイティブビルドの失敗 (native build failed)
- **VLT-LAYER-001**: 互換性のないアーキテクチャ (incompatible architecture)
- **VLT-SCHED-001**: 無効なスケジュール式 (invalid schedule expression)
- **VLT-EFS-001**: EFSアクセスポイントが見つからない (access point not found)
- **VLT-EFS-2049-INGRESS**: NFS インバウンド設定不足 (missing NFS ingress)
- **VLT-EFS-2049-EGRESS**: NFS アウトバウンド設定不足 (missing NFS egress)
- **VLT-AWS-ACCOUNT-001**: AWSアカウント情報の不整合 (account mismatch)
- **VLT-IAM-001**: ステージポリシーによるワイルドカード指定の拒否 (wildcard denied by stage policy)
- **VLT-CFN-001**: 変更セット（Change Set）の作成失敗 (change set creation failed)

## 診断情報の構造

出力される各診断情報には、エラーコード、重要度（Severity）、概要、エビデンス（検証データ）、影響を受ける定義ファイルのパス、推奨されるアクション、および任意の AWS リソース識別子（ARNなど）が含まれます。エラーメッセージのテキスト表現は本プロジェクト独自のものであり、他のいかなるフレームワークの表現や言い回しも模倣してはなりません。
