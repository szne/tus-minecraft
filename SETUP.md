# セットアップガイド

東京理科大学マインクラフトサークル（仮）サーバーの構築手順です。

---

## 📁 ファイル構成

```
tus_minecraft/
├── Dockerfile              # Paper サーバーのコンテナ定義
├── docker-compose.yml      # サービス構成（Minecraft + playit.gg）
├── .env.example            # 環境変数のテンプレート
├── .gitignore
├── scripts/
│   └── start.sh            # 起動スクリプト（Paper・プラグイン自動DL）
├── config/
│   └── server.properties   # サーバー設定テンプレート
└── data/                   # ★ サーバーデータ（Git管理外・永続化）
    └── .gitkeep
```

`data/` ディレクトリにワールドデータ・プラグイン設定・ログなどが蓄積されます。
Git にはコミットされないため、バックアップは別途行ってください。

---

## 🚀 初回セットアップ（自宅 Mac）

### 1. リポジトリをクローン

```bash
git clone <your-repo-url> tus_minecraft
cd tus_minecraft
```

### 2. 環境変数を設定

```bash
cp .env.example .env
```

`.env` を編集して Discord Bot Token を設定:

```env
MEMORY=4G                        # Mac の RAM が 16GB なら 6G 推奨
DISCORD_BOT_TOKEN=xxxxxxxxxxxxxx  # Discord Developer Portal で取得
```

### 3. 起動

```bash
docker compose up -d
```

初回起動時は以下が自動実行されます（数分かかります）:
- Paper MC 最新安定版のダウンロード
- 6つのプラグインのダウンロード
- EULA の自動承認
- `server.properties` テンプレートのコピー

### 4. ログ確認

```bash
docker compose logs -f minecraft
```

`Done (XX.XXXs)! For help, type "help"` が表示されたら起動完了です。

---

## 🌐 外部公開（playit.gg）

ルーターのポート開放が不要な `playit.gg` を使います。

### セットアップ手順

1. `docker-compose.yml` の `playit:` セクションのコメントを外す
2. `docker compose up -d playit`
3. ログに表示される URL をブラウザで開いて認証
4. `./playit-data/` にトークンが保存され、以降は自動接続

```bash
docker compose logs playit
# → Visit https://playit.gg/claim/XXXXXXXX to claim your agent
```

---

## 🔧 プラグイン設定

### DiscordSRV（Discord 連携）

初回起動後、`data/plugins/DiscordSRV/config.yml` が生成されます。

**必須設定:**
```yaml
BotToken: "your-bot-token"   # ← .env の DISCORD_BOT_TOKEN で自動注入
Channels:
  global: "your-channel-id"  # ← マイクラチャットを同期する Discord チャンネルID
```

Bot Token は `.env` に設定してあれば再起動時に自動注入されます。

### LuckPerms + DiscordSRV（権限の Discord ロール連携）

サーバーに接続後、以下のコマンドで権限グループを作成:

```
/lp creategroup admin
/lp creategroup user
/lp creategroup ob
```

DiscordSRV の `synchronization.yml` でロール ID と紐付け:

```yaml
# data/plugins/DiscordSRV/synchronization.yml
# Discord ロールID → LuckPerms グループ
GroupSynchronizationPrimaryGroup:
  "123456789012345678": "admin"   # Discord Admin ロールID
  "234567890123456789": "user"    # Discord User ロールID
  "345678901234567890": "ob"      # Discord OB ロールID
```

### Multiverse-Core（マルチワールド）

readme.md のワールド構成を作成するコマンド:

```
/mv create lobby normal         # 共通ロビーワールド
/mv create season2026 normal    # 2026 生活ワールド
/mv create campus creative      # 学祭・キャンパス再現ワールド（クリエイティブ）
/mv create resources normal     # 資源採取ワールド（定期リセット用）
```

---

## 🖥 VPS 移行手順（スケールアップ時）

Docker 環境のため移行は非常に簡単です。

### ConoHa VPS / Xserver VPS への移行

```bash
# 1. VPS に Docker をインストール
curl -fsSL https://get.docker.com | sh

# 2. このリポジトリをクローン
git clone <your-repo-url> tus_minecraft
cd tus_minecraft

# 3. .env を設定
cp .env.example .env && vi .env

# 4. data/ のバックアップを転送（ワールドデータを引き継ぐ場合）
rsync -avz --progress ./data/ user@vps-ip:~/tus_minecraft/data/

# 5. 起動
docker compose up -d
```

### クロスプラットフォームビルド（M1 Mac で VPS 向けイメージをビルドする場合）

```bash
# linux/amd64 向けにビルドして Docker Hub に push
docker buildx build --platform linux/amd64 -t yourname/tus-minecraft:latest --push .
```

VPS 側の `docker-compose.yml` で `build:` を `image: yourname/tus-minecraft:latest` に変更。

---

## 🛠 よく使うコマンド

```bash
# 起動
docker compose up -d

# 停止
docker compose down

# ログ確認
docker compose logs -f minecraft

# サーバーコンソールに接続（/stopなどのコマンドを打てる）
docker attach tus-minecraft
# 切断は Ctrl+P → Ctrl+Q（Ctrl+C だとサーバーが停止するので注意）

# プラグインを再ダウンロードしたい場合
rm data/plugins/PluginName.jar
docker compose restart minecraft

# バックアップ
tar -czf backup-$(date +%Y%m%d).tar.gz data/
```

---

## ⚙ MEMORY の目安

| VPS/Mac の RAM | 推奨 MEMORY |
|:---:|:---:|
| 2 GB | 1G |
| 4 GB | 2G〜3G |
| 8 GB | 4G〜6G |
| 16 GB (Mac M1) | 6G〜8G |
