# ドメインモデル (Domain Model)

## アプリケーション (Application)

属性（Attributes）: 名前（name）、リージョン（region）、ステージ（stage）、AWSアカウント制限（account constraint）、ランタイムデフォルト（runtime defaults）、関数（functions）、レイヤー（layers）、スケジュール（schedules）、マウント設定（mounts）、ポリシー（policies）、タグ（tags）。

## 関数 (Function)

属性（Attributes）: 論理名（logical name）、ハンドラー（handler）、ランタイム（runtime）、アーキテクチャ（architecture）、メモリ（memory）、タイムアウト（timeout）、エフェメラルストレージ（ephemeral storage）、環境変数（environment）、VPC参照（VPC reference）、レイヤー（layers）、マウント設定（mounts）、IAMケーパビリティ（IAM capabilities）、同時実行数（concurrency）、ログ設定（logging）。

不変条件（Invariants）:
- タイムアウト値が AWS Lambda の制限範囲内であること。
- すべてのマウントパスが `/mnt/` で始まっていること。
- アーキテクチャがアタッチされているすべての Layer と互換性があること。
- 参照されている Layer およびマウント設定が存在すること。
- ステージ統合（stage merge）後に、重複する環境変数のキーが存在しないこと。

## レイヤー (Layer)

属性（Attributes）: 名前（name）、ソース指定（source specification）、互換ランタイム（compatible runtimes）、アーキテクチャ（architectures）、ビルド環境（build environment）、保持ポリシー（retention policy）、説明（description）、ライセンスメタデータ（license metadata）、コンテンツハッシュ（content hash）。

## スケジュール (Schedule)

属性（Attributes）: 名前（name）、ターゲット関数（target function）、式タイプ（expression type）、式（expression）、タイムゾーン（timezone）、状態（state）、柔軟な実行ウィンドウ（flexible window）、インプット（input）、再試行ポリシー（retry policy）、DLQ、実行ロール（execution role）。

## EFSマウント (EFS Mount)

属性（Attributes）: シンボリック名（symbolic name）、アクセスポイントソース（access-point source）、ローカルパス（local path）、期待するVPC構成（VPC expectations）、任意のPOSIX構成（POSIX expectations）、診断ポリシー（diagnostic policy）。

## ケーパビリティベースのIAM (Capability-based IAM)

関数は、`read_from_s3`、`write_to_s3`、`read_parameter`、あるいは明示的なアクションなどの「ケーパビリティ」を宣言します。ケーパビリティの展開はバージョン管理され、レビュー可能であり、生成されたマニフェスト内で確認できます。ワイルドカードは、ステージポリシーに従って警告またはエラーを出力します。
