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

## arm64 (AWS Graviton) アーキテクチャビルド

`architecture: :arm64` を指定することで、AWS Graviton プロセッサ（`arm64`）向けのネイティブ拡張コンパイルおよび CloudFormation 出力（関数・Layer）を自動化できます。

### DSL 設定例 (`Veltrunodefile`)

アプリケーション全体のデフォルト（`runtime ..., architecture: :arm64` または `architecture :arm64`）、または個別の `function` / `layer` で `architecture: :arm64` を指定できます。`layer` 側で `architectures` を明示指定していない場合、アタッチ先の関数やアプリケーションの `architecture: :arm64` が自動的に伝搬されます。

```ruby
Veltrunode.application "graviton-service" do
  aws region: "ap-northeast-1", account: "123456789012"
  runtime ruby: "3.3", architecture: :arm64

  layer :runtime_gems do
    bundle lockfile: "Gemfile.lock"
    build_on :amazon_linux_2023
  end

  function :worker do
    handler "functions/worker.handler"
    attach_layer :runtime_gems
  end
end
```

### 自動化される動作

1. **Docker コンテナによる arm64 ネイティブ拡張ビルド (`NativeBuilder` / `ContainerRunner`)**:
   - `build_on :amazon_linux_2023` が設定された Layer のビルド時、`--platform linux/arm64` および `arm64` 向けビルドイメージダイジェストを自動選択してネイティブ Gem（または Python / Node.js パッケージ）をコンパイルします。
2. **Lambda 関数のアーキテクチャ設定 (`AWS::Lambda::Function`)**:
   - CloudFormation テンプレートの `Properties.Architectures` に `['arm64']` が出力されます。
3. **Layer の互換性アーキテクチャ設定 (`AWS::Lambda::LayerVersion`)**:
   - CloudFormation テンプレートの `Properties.CompatibleArchitectures` に `'arm64'` が出力されます。

## Rust / Go カスタムランタイム (`runtime: 'provided.al2023'`)

超低レイテンシ・高スループットが求められるワークロード向けに、`runtime: 'provided.al2023'` と Cargo (Rust) / Go ビルドパイプラインを統合し、単一実行可能バイナリ（`bootstrap`）を決定論的にビルド・パッケージングできます。

### DSL 設定例 (`Veltrunodefile`)

```ruby
Veltrunode.application "low-latency-service" do
  aws region: "ap-northeast-1", account: "123456789012"
  runtime "provided.al2023", architecture: :arm64

  # 1. Rust (Cargo) による musl 静的リンクビルド
  function :rust_processor do
    cargo do
      manifest "./Cargo.toml"
      bin "processor"
      docker true
      locked true
    end
  end

  # 2. Go による CGO_ENABLED=0 静的リンクビルド
  function :go_ingestor, architecture: :x86_64 do
    go package: "./cmd/ingestor", ldflags: "-s -w", docker: true
  end
end
```

### 自動化される動作 (`Veltrunode::Build::CustomRuntimeBuilder`)

1. **`bootstrap` 実行可能ファイルの決定論的ビルド**:
   - **Cargo (Rust)**: `CARGO_INCREMENTAL=0`, `SOURCE_DATE_EPOCH=1704067200`, `RUSTFLAGS="-C target-feature=+crt-static -C link-arg=-s --remap-path-prefix=..."` を設定し、`cargo build --release --locked` で再現可能なバイナリを生成します。
   - **Go**: `CGO_ENABLED=0`, `GOOS=linux`, `GOARCH=amd64|arm64`, `SOURCE_DATE_EPOCH=1704067200` を設定し、`go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -tags netgo,osusergo -o bootstrap` で決定論的バイナリを生成します。
2. **Docker コンテナ内での静的リンク（musl 等）クロスコンパイル**:
   - 関数の `architecture`（`:x86_64` -> `x86_64-unknown-linux-musl` / `GOARCH=amd64`、`:arm64` -> `aarch64-unknown-linux-musl` / `GOARCH=arm64`）に応じて `--platform linux/amd64` または `linux/arm64` のコンテナ内でクロスコンパイルを実行します。
3. **ZIP アーカイブ内ルートへの `bootstrap` 配置**:
   - コンパイルされたバイナリを実行権限（`0755`）付きの `bootstrap` として ZIP アーカイブのルート直下に配置し、CloudFormation の `AWS::Lambda::Function` に `Runtime: provided.al2023` および `Handler: bootstrap` を出力します。

## Node.js / TypeScript バンドルビルド (`esbuild` / `Bun`)

Node.js / TypeScript 製の Lambda 関数において、`entry: 'src/handler.ts'` を指定することで `esbuild` または `Bun` による高速トランスパイル・Tree-shaking・バンドルを実行し、最小化された ZIP パッケージを直接生成できます。

### DSL 設定例 (`Veltrunodefile`)

```ruby
Veltrunode.application "ts-microservice" do
  aws region: "ap-northeast-1", account: "123456789012"

  # 1. キーワード引数でのシンプルな TypeScript エントリ・Source Map 指定
  function :api_handler, runtime: "nodejs20.x", entry: "src/handler.ts", sourcemap: true do
    memory 512
  end

  # 2. esbuild ブロックによる詳細設定（Tree-shaking・Minify・外部モジュール除外）
  function :order_worker do
    runtime "nodejs20.x"
    esbuild do
      entry "src/worker.ts"
      sourcemap :external # true, :inline, :external, :linked, :both
      minify true
      tree_shaking true
      external "@aws-sdk/*"
      target "node20"
    end
  end

  # 3. Bun バンドラーの利用
  function :fast_webhook do
    runtime "nodejs20.x"
    bun entry: "src/webhook.ts", sourcemap: :inline, minify: true
  end
end
```

### 自動化される動作 (`Veltrunode::Build::NodeBundleBuilder`)

1. **`esbuild` / `Bun` による高速トランスパイル・Tree-shaking・バンドル**:
   - `esbuild <entry> --bundle --platform=node --target=node20 --format=cjs --tree-shaking=true`（または `bun build <entry> --target=node`）を実行し、不要なコードを除去した単一バンドルを生成します。
   - `handler` 未指定時はエントリファイル名から自動的に CloudFormation の `Handler`（例: `src/handler.ts` -> `handler.handler`）を導出します。
2. **Source Map 出力オプション (`sourcemap`)**:
   - `sourcemap: true`（または `:external` / `:linked`）を指定すると、`--sourcemap` オプションを付与して `<outfile>.map`（例: `handler.js.map`）を生成し、バンドル済み JS ファイルとともに ZIP アーカイブへ同梱します。
   - `sourcemap: :inline` を指定すると、`--sourcemap=inline` によりインライン Source Map を JS ファイル内に埋め込みます。

## Python `uv` / `Poetry` 高速レイヤービルド

Python プロジェクトにおいて、`pyproject.toml`（PEP 621 / Poetry）または `requirements.txt` から `uv` を用いて高速な依存解決と Linux 向けバイナリホイール取得を行い、Lambda 互換の `python/lib/python3.x/site-packages` 構造レイヤー ZIP を自動生成できます。

### DSL 設定例 (`Veltrunodefile`)

```ruby
Veltrunode.application "python-ai-service" do
  aws region: "ap-northeast-1", account: "123456789012"
  runtime python: "3.12", architecture: :arm64

  # 1. uv による pyproject.toml / uv.lock からのレイヤー生成
  layer :ai_deps do
    uv pyproject: "pyproject.toml", lockfile: "uv.lock", extras: [:aws], only_binary: true
  end

  # 2. Poetry プロジェクト (pyproject.toml / poetry.lock) からのレイヤー生成
  layer :poetry_deps, architecture: :x86_64 do
    poetry pyproject: "pyproject.toml", lockfile: "poetry.lock", without: %i[dev test]
  end

  function :inference do
    handler "app.handler"
    attach_layer :ai_deps
  end
end
```

### 自動化される動作 (`Veltrunode::Build::PythonUvLayerBuilder`)

1. **`uv` を利用した高速な依存解決とホイールダウンロード**:
   - `uv pip install --requirement <pyproject.toml|requirements.txt> --target <site-packages> --only-binary :all: --no-cache` を実行し、高速な依存解決とホイール展開を行います。
2. **`python/lib/python3.x/site-packages` 構造のレイヤー ZIP 自動生成**:
   - Layer の `compatible_runtimes`（例: `python3.12`）に合わせて `python/lib/python3.12/site-packages/` ディレクトリ構造を自動構築し、決定論的なレイヤー ZIP を出力します。
3. **Linux `x86_64` / `arm64` 向けバイナリホイールの自動取得**:
   - Layer のターゲットアーキテクチャ（`:x86_64` -> `--python-platform x86_64-unknown-linux-gnu` / `manylinux2014_x86_64`、`:arm64` -> `--python-platform aarch64-unknown-linux-gnu` / `manylinux2014_aarch64`）を指定し、macOS 等の異なるホスト OS 上からでも Lambda 実行環境向けの Linux バイナリホイールを自動取得します。
