# ビルドとパッケージング (Build and Packaging)

## 再現性 (Reproducibility)

- Gemfile.lock の設定内容を厳格に遵守します。
- 可能な限り、ビルドイメージをダイジェスト値で固定（ピン留め）します。
- ファイルの順序および ZIP メタデータを正規化します。
- Ruby、Bundler、OSイメージ、CPUアーキテクチャ、および本ツールのバージョン情報を記録します。
- 宣言されていない未定義の依存関係の取得を防止します。

## ビルドフェーズ (Build Phases)

1. ソースコードおよび依存関係のインプット情報を検出します。
2. 包含/除外（include/exclude）ルールを適用します。
3. Bundler グループを解決します。
4. 必要に応じて、コンテナ内でネイティブ依存関係のビルドを実行します。
5. Layer および関数のディレクトリ構造を組み立てます。
6. パッケージ検証（バリデーション）を実行します。
7. 決定論的な（再現可能な）ZIP アーカイブを作成します。
8. SHA-256 ハッシュ値を計算します。
9. マニフェストファイルを出力します。

## キャッシュ (Cache)

ビルドキャッシュは、Lambda 関数およびレイヤーのコンテンツハッシュ（SHA-256）に基づいて決定論的に管理されます。

### ローカルキャッシュとリモートキャッシュの併用
- **ローカルキャッシュ**: デフォルトで `.veltrunode/cache` ディレクトリ内に保存されます。ローカルにキャッシュが存在する場合はネットワーク通信を行わずに即座に復元されます。
- **S3 リモートキャッシュ**: CI/CD 環境などローカルキャッシュが永続化されない環境向けに、Amazon S3 バケットをリモートキャッシュバックエンドとして使用できます。
- **併用動作**: リモートキャッシュからアーティファクトをダウンロードした際、ローカルキャッシュにも同時に昇格・保存されます。ビルド完了時にはローカルキャッシュとリモートキャッシュの双方が更新されます。

### 設定例 (Veltrunodefile)
```ruby
Veltrunode.application "document-converter" do
  # ハッシュ形式での指定
  cache remote: {
    s3: {
      bucket: "my-build-cache-bucket",
      prefix: "build-cache" # 任意（未指定時はバケット直下）
    }
  }

  # またはブロック構文での指定
  # cache do
  #   remote do
  #     s3 bucket: "my-build-cache-bucket", prefix: "build-cache"
  #   end
  # end
end
```

### キャッシュ汚染の防止 (Anti-Poisoning)
ダウンロードされたキャッシュアーティファクト（ZIP ファイル）は、メタデータに記録された SHA-256 ハッシュ値と照合検証されます。ハッシュの不一致や破損が検出された場合、該当のキャッシュは安全に破棄（無効化）され、通常の新規ビルドにフォールバックします。

### 耐障害性 (Fault Tolerance)
リモート S3 バケットへのアクセス障害、ネットワーク断、認証エラー、あるいはオブジェクト未存在（キャッシュミス）などの場合でも、ビルド処理は中断されず、ローカルビルドを継続します。


## 機密情報・シークレット (Secrets)

機密情報（シークレット）をパッケージやテンプレート内に直接埋め込んではなりません。
`veltrunode validate` によるパッケージング前バリデーションフェーズおよび `veltrunode build` によるパッケージングフェーズにおいて、シークレットスキャン（`SecretScanner`）が自動的に実行されます。

### スキャン対象パターン
- **ファイル名パターン**: `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa`, `credentials`, `*.secret`（大文字・小文字を区別せず検出）
- **機密文字列パターン**: AWS アクセスキー・秘密鍵ヘッダ等の既知パターン
- **高エントロピー文字列**: Shannon エントロピー計算による API キーや認証トークン候補の検出

### 診断と警告
機密情報が疑われるファイルが検出された場合、診断情報 `VLT-BUILD-SECRET-WARN`（重要度: `warning`）が出力されます。

> **免責事項（スキャンの限界について）**
> 本スキャナーは静的ヒューリスティックおよびエントロピー計算に基づく事前検知を行うものであり、あらゆる機密情報の完全な検出を保証するものではありません。アプリケーション内で機密情報を利用する場合は、ソースコードや設定ファイルに直接埋め込まず、AWS Secrets Manager や AWS Systems Manager Parameter Store 等の安全なシークレット管理サービスの利用を推奨します。

## OCI コンテナイメージパッケージング (`PackageType: Image`)

ZIP アーカイブのサイズ上限（展開時 250 MB）を超える大規模な機械学習モデルやネイティブ依存ライブラリを含む Lambda 関数を、OCI コンテナイメージ（最大 10 GB）としてビルド・プッシュ・デプロイできます。

### DSL 設定例 (`Veltrunodefile`)

`function` のキーワード引数、`image` メソッド、または `image do ... end` ブロック構文で `Dockerfile` や既存 ECR イメージ URI を指定できます。

```ruby
Veltrunode.application "ml-inference-service" do
  aws region: "ap-northeast-1", account: "123456789012"

  # 1. Dockerfile からビルドして ECR に自動プッシュする構成
  function :ml_inference, image: { dockerfile: "./Dockerfile", tag: "v1.2.0" } do
    architecture :arm64
    memory 4096
    timeout 120
  end

  # 2. ブロック構文による詳細設定（ビルド引数・ターゲット・ImageConfig オーバーライド）
  function :vision_classifier do
    architecture :x86_64
    image do
      dockerfile "./docker/Dockerfile.vision"
      context "."
      repository "ml/vision-classifier"
      tag "2026.11"
      target "production"
      build_args MODEL_BUCKET: "my-models"
      command ["app.handler"]
      working_directory "/var/task"
    end
  end

  # 3. 既存の ECR コンテナイメージ URI または CloudFormation パラメータ参照
  function :prebuilt_scorer do
    image uri: "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/scorer:v1.0.0"
  end
end
```

### Docker ビルドと ECR 自動プッシュ

- **Docker ビルド (`Veltrunode::Build::ImageBuilder`)**:
  - 関数の `architecture`（`:x86_64` -> `linux/amd64`, `:arm64` -> `linux/arm64`）に合わせて `--platform` を自動指定し、`docker build`（または `podman build`）を実行します。
  - `Dockerfile` の内容・アーキテクチャ・ビルド引数・ターゲットステージから決定論的な SHA-256 コンテンツハッシュを算出し、`build/manifest.json` に記録します。
- **ECR 自動プッシュ (`Veltrunode::AWS::EcrPusher`)**:
  - デプロイ時に ECR リポジトリの存在を確認し、未作成の場合はスキャン有効化（`scan_on_push: true`）および暗号化（`AES256`）付きで自動作成します。
  - `ecr:GetAuthorizationToken` で取得したトークンを用いてレジストリ認証を行い、イメージのタグ付けとプッシュを自動実行します。

### CloudFormation コンパイル (`PackageType: Image`)

コンテナイメージ関数は `AWS::Lambda::Function` リソースにおいて以下のようにコンパイルされます。

- `PackageType: Image` が設定され、コンテナイメージ関数では不要（かつ CloudFormation 仕様上禁止）な `Handler`, `Runtime`, `Layers` プロパティは自動的に省略されます。
- `Code.ImageUri` に ECR イメージ URI（または `Fn::Sub` / `Ref`）が出力されます。
- `command`, `entry_point`, `working_directory` を指定した場合は `ImageConfig` プロパティに出力されます。
