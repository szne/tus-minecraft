# 理科大マイクラ部 サーバー運用ガイド

Paper 1.21.x / Docker 構成のサーバー運用手順書です。

---

## 目次

1. [サーバー管理の基本](#1-サーバー管理の基本)
2. [管理者コンソールへの入り方](#2-管理者コンソールへの入り方)
3. [OP権限の付与](#3-op権限の付与)
4. [複数ワールドの作成（Multiverse-Core）](#4-複数ワールドの作成multiverse-core)
5. [荒らし対策ログ（CoreProtect）](#5-荒らし対策ログcoreprotect)
6. [権限管理（LuckPerms）](#6-権限管理luckperms)
7. [Discord連携（DiscordSRV）](#7-discord連携discordsrv)
8. [Bedrock接続（GeyserMC）](#8-bedrock接続geysermc)
9. [ローマ字→日本語変換（JapanizeChat）](#9-ローマ字日本語変換japanizechat)
10. [便利コマンド（EssentialsX）](#10-便利コマンドessentialsx)
11. [ホワイトリスト管理](#11-ホワイトリスト管理)
12. [バックアップ](#12-バックアップ)

---

## 1. サーバー管理の基本

```bash
# 起動
docker compose up -d

# 停止
docker compose down

# 再起動（server.properties などの設定変更後）
docker compose restart minecraft

# ログをリアルタイム確認（Ctrl+C で抜けてもサーバーは止まらない）
docker compose logs -f minecraft

# Dockerfile / start.sh を変更した場合は --build が必要
docker compose up -d --build
```

---

## 2. 管理者コンソールへの入り方

サーバーコンソールに接続してコマンドを直接実行する方法です。

```bash
docker attach tus-minecraft
```

- ゲーム内と違い **スラッシュ不要**（例: `op 名前`、`whitelist add 名前`）
- **切断は `Ctrl+P` → `Ctrl+Q`**（`Ctrl+C` を押すとサーバーが止まるので注意！）

---

## 3. OP権限の付与

### コンソールから（最も確実）

```bash
docker attach tus-minecraft
# コンソールに入ったら（/ は不要）:
op ユーザー名
```

### ゲーム内から（自分が既にOPの場合）

```
/op ユーザー名
```

### ops.json を直接書き込む（コンソールが使えない場合）

```bash
# 1. Java ユーザーのUUIDを Mojang API で取得
curl -s https://api.mojang.com/users/profiles/minecraft/ユーザー名 | python3 -m json.tool

# 2. UUID を 8-4-4-4-12 形式に変換して data/ops.json に追記
```

`data/ops.json` の形式:
```json
[
  {
    "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "name": "ユーザー名",
    "level": 4,
    "bypassesPlayerLimit": false
  }
]
```

編集後は `docker compose restart minecraft` で反映。

---

## 4. 複数ワールドの作成（Multiverse-Core）

> **⚠️ v5.x の変更点**: ワールドへのテレポートに `w:` プレフィックスが必要になりました。
> 旧: `/mv tp world名` → 新: `/mvtp w:world名`

### 基本操作

```
/mv list                # ワールド一覧
/mvtp w:ワールド名       # ワールドへ移動
/mv who                 # 各ワールドにいるプレイヤー一覧
```

### ワールド構成を作る

```
# 共通ロビー
/mv create lobby normal

# 今年の生活ワールド
/mv create season2026 normal

# 学祭・キャンパス再現（クリエイティブ固定）
/mv create campus creative
/mv modify set gamemode creative campus

# 資源採取ワールド（定期リセット用）
/mv create resources normal
```

### ワールドをアーカイブ（読み取り専用）にする

```
# OBが観光だけできる設定
/mv modify set allowbuild false 過去ワールド名
/mv modify set allowbreak false 過去ワールド名
```

### スポーン地点を設定する

```
/mv setspawn          # 今いる場所を現在のワールドのスポーンに設定
```

### ワールド別テレポート権限（LuckPerms 連携）

Multiverse-Core 5.x では `use-finer-teleport-permissions: true`（デフォルト有効）のとき、  
ワールドごとに権限 `multiverse.teleport.self.w.<ワールド名>` でアクセスを制限できます。

**サバイバル↔クリエイティブ間の移動のみ許可する例:**

```
# user グループに season2026 と campus ワールドのみ許可
/lp group user permission set multiverse.teleport.self.w.season2026 true
/lp group user permission set multiverse.teleport.self.w.campus true

# ワイルドカードは与えない（ネザー・エンド・他ワールドには移動不可）
# /lp group user permission set multiverse.teleport.self true  ← これはやらない
```

> **ポイント**: ネザー（`world_nether`）やエンド（`world_the_end`）の権限を付与しなければ、  
> `/mvtp w:world_nether` しようとしても「権限がありません」になります。

### 資源ワールドのリセット手順

```bash
# コンソールでワールドをアンロード
/mv unload resources

# サーバーを止めてデータ削除
docker compose stop minecraft
rm -rf data/resources data/resources_nether

# 再起動してワールドを再作成
docker compose start minecraft
# ゲーム内:
/mv create resources normal
```

---

## 5. 荒らし対策ログ（CoreProtect）

### ブロックの操作履歴を調べる

```
/co inspect
# → このモードでブロックを左クリックすると「誰が・いつ」操作したか表示
# もう一度 /co inspect でモード終了
```

### 特定プレイヤーの操作を検索

```
/co lookup user:名前 time:24h
/co lookup user:名前 time:7d action:+block   # ブロック設置のみ
/co lookup user:名前 time:7d action:-block   # ブロック破壊のみ
```

### 荒らしをロールバック（巻き戻す）

```
# 半径50ブロック以内の名前の操作を24時間分巻き戻す
/co rollback user:名前 time:24h radius:50
/co confirm   # 確認して実行
```

### ロールバックを取り消す

```
/co restore user:名前 time:24h radius:50
/co confirm
```

---

## 6. 権限管理（LuckPerms）

### グループ構成（推奨）

| グループ | 対象 | 権限レベル |
|:--|:--|:--|
| `admin` | 管理者 | 全コマンド・OP相当 |
| `user` | 現役生 | 通常プレイ・建築 |
| `ob` | 卒業生 | 観光のみ（建築不可） |

### グループを作成する

```
/lp creategroup admin
/lp creategroup user
/lp creategroup ob
```

### プレイヤーをグループに割り当てる

```
/lp user プレイヤー名 parent set user
/lp user プレイヤー名 parent set admin
/lp user プレイヤー名 parent set ob
```

### グループに権限を設定する

```
# user グループにマルチワールドのテレポート権限
/lp group user permission set multiverse.teleport.self true
/lp group user permission set multiverse.access.* true

# ob グループは建築不可
/lp group ob permission set multiverse.build false
```

### 権限を確認する

```
/lp user プレイヤー名 permission info
/lp group user permission info
```

---

## 7. Discord連携（DiscordSRV）

### 初期設定チェックリスト

- [ ] Bot をDiscordサーバーに招待済み
- [ ] [Developer Portal](https://discord.com/developers/applications) → Bot → **SERVER MEMBERS INTENT** と **MESSAGE CONTENT INTENT** を ON
- [ ] `.env` に `DISCORD_BOT_TOKEN` と `DISCORD_CHANNEL_ID` を設定済み

### Bot Token・チャンネルIDの設定

`.env` に設定するだけで起動時に自動注入されます:

```env
DISCORD_BOT_TOKEN=your_bot_token_here
DISCORD_CHANNEL_ID=123456789012345678
```

> **チャンネルIDの確認方法**: Discord 設定 → 詳細設定 → 開発者モード ON → チャンネルを右クリック → 「IDをコピー」

設定後:
```bash
docker compose restart minecraft
```

### ゲーム内チャットの Discord 表示について

DiscordSRV は以下の形式でメッセージを転送します:

| ゲーム内入力 | Discord に届く内容 |
|:--|:--|
| ローマ字（例: `konnichiha`） | `konnichiha (こんにちは)` |
| 日本語直打ち（例: `こんにちは`） | `こんにちは` |
| 英語（例: `Hello!`） | `Hello!` |

ローマ字入力は JapanizeChat + JapanizeDiscordBridge により自動変換されます（→ [9章](#9-ローマ字日本語変換japanizechat)）。

### Discord ロールでゲーム内権限を自動連携

`data/plugins/DiscordSRV/synchronization.yml` を編集:

```yaml
GroupSynchronizationPrimaryGroup:
  "DiscordロールのID": "luckpermsグループ名"

# 例:
# "123456789012345678": "admin"
# "234567890123456789": "user"
# "345678901234567890": "ob"
```

> **ロールIDの確認方法**: Discord で対象ロールを右クリック → 「IDをコピー」

---

## 8. Bedrock接続（GeyserMC）

スマホ（iOS/Android）・Switch・Windows 10/11 版から接続できます。

### 接続先

| 項目 | 値 |
|:--|:--|
| サーバーアドレス | playit.gg のURL（外部）または LAN IP（LAN内） |
| ポート | `19132` |

### 手順（iOS/Android）

1. Minecraft 起動 → **「遊ぶ」**
2. **「サーバー」タブ** → **「サーバーを追加」**
3. アドレスと `19132` を入力 → 接続

### Bedrockプレイヤーへの注意点

- Microsoft アカウントで接続（Java アカウント不要）
- ゲーム内名は `.` から始まる（例: `.szkk`）
- ホワイトリストに追加する場合はこのドット付きの名前を使う

---

## 9. ローマ字→日本語変換（JapanizeChat）

ローマ字で入力すると、Google IME API によってリアルタイムで日本語に変換して表示されます。

### ゲーム内の表示

```
# 入力:
konnichiha

# ゲーム内表示（本人・周囲のプレイヤー）:
konnichiha (こんにちは)

# Discord に届く内容:
konnichiha (こんにちは)
```

### プレイヤーごとのオン/オフ切り替え

変換表示はデフォルトでオン。プレイヤーが自分のセッション中だけオフにすることもできます:

```
/jp toggle    # オン/オフ切り替え
```

### 変換色の変更（管理者）

`data/plugins/JapanizeChat/config.yml` を編集:

```yaml
# gray / white / gold / aqua / yellow / green / light_purple / red
# hex形式（#FFFFFFなど）も可
converted-text-color: "gray"

# サーバー参加時のデフォルト状態
default-toggle-state: true
```

編集後は `/plugman reload JapanizeChat` または `docker compose restart minecraft` で反映。

---

## 10. 便利コマンド（EssentialsX）

EssentialsX はホーム設定・ワープ・テレポート・経済など、サーバー運用に欠かせないコマンドを追加するプラグインです。

### ホーム（個人拠点）

```
/sethome          # 現在地をホームに設定
/sethome 名前      # 複数ホームに名前をつけて設定（OP・権限が必要）
/home             # ホームにテレポート
/home 名前         # 指定ホームにテレポート
/delhome 名前      # ホームを削除
/homes            # ホーム一覧
```

### ワープ（管理者が設定する公共の拠点）

```
/setwarp ワープ名         # 現在地をワープポイントに設定（OP）
/warp ワープ名            # ワープポイントへ移動
/warp                    # ワープ一覧を表示
/delwarp ワープ名         # ワープポイントを削除（OP）
```

### テレポート

```
/tp プレイヤー名          # 指定プレイヤーの場所にテレポート（OP）
/tpa プレイヤー名         # テレポートリクエストを送る
/tpaccept                # テレポートリクエストを承認
/tpdeny                  # テレポートリクエストを拒否
/back                    # 直前の場所に戻る（死亡後も使える）
/spawn                   # スポーン地点に戻る
```

### 情報・ユーティリティ

```
/afk                     # AFKモードのオン/オフ
/msg プレイヤー名 内容     # プライベートメッセージ
/r 内容                   # 直前のメッセージに返信
/seen プレイヤー名         # 最終ログイン日時を確認（OP）
/whois プレイヤー名        # プレイヤー情報（IP・接続回数など）（OP）
/gamemode survival/creative 名前  # ゲームモード変更（OP）
```

### 経済（Economy）

EssentialsX Economy を有効にするとコイン・取引システムが使えます（Vault 連携が必要）。

```
/balance              # 所持金を確認
/pay プレイヤー名 金額  # プレイヤーに送金
/eco give 名前 金額    # 管理者が直接付与（OP）
/eco take 名前 金額    # 管理者が直接削除（OP）
```

### 管理者向けコマンド

```
/kick プレイヤー名 理由        # キック
/ban プレイヤー名 理由         # BANする
/unban プレイヤー名            # BAN解除
/mute プレイヤー名             # チャット禁止
/fly プレイヤー名              # フライトのオン/オフ
/god プレイヤー名              # 無敵モードのオン/オフ
/invsee プレイヤー名           # インベントリを見る
/essentials reload             # 設定ファイルをリロード
```

### 設定のポイント

`data/plugins/Essentials/config.yml` の主要設定:

```yaml
# チャットフォーマットは DiscordSRV / JapanizeChat と競合するため無効化推奨
# EssentialsXChat プラグインを入れなければ自動的にチャット干渉なし

# テレポートのクールダウン（秒）
teleport-cooldown: 3

# テレポート時にプレイヤーが動くとキャンセル
teleport-safety: true

# /back で死亡地点に戻れるようにする
respawn-listener-priority: HIGH

# ホームの最大数（デフォルト: 1）
sethome-multiple:
  default: 1
  vip: 5
```

---

## 11. ホワイトリスト管理

### オン/オフ

`data/server.properties` を編集して `docker compose restart minecraft` で反映:

```properties
# 誰でも入れる（開発・テスト中）
white-list=false

# 登録者のみ（運用開始後）
white-list=true
enforce-whitelist=true
```

### プレイヤーを追加/削除

```
/whitelist add ユーザー名      # Java版
/whitelist add .ユーザー名    # Bedrock版（ドットつき）
/whitelist remove ユーザー名
/whitelist list
```

> **DiscordSRV 連携後**: Discord で認証コマンドを打ったユーザーが自動でホワイトリストに追加されます。手動管理不要になります。

---

## 12. バックアップ

### 手動バックアップ

```bash
# data/ 全体（完全バックアップ）
tar -czf backup-$(date +%Y%m%d-%H%M).tar.gz data/

# ワールドだけ（軽量）
tar -czf world-$(date +%Y%m%d).tar.gz \
  data/world data/world_nether data/world_the_end data/season2026
```

### バックアップから復元

```bash
docker compose down
tar -xzf backup-20260101-1200.tar.gz
docker compose up -d
```

---

## よく使うコマンド早見表

| やりたいこと | コマンド（コンソール or ゲーム内） |
|:--|:--|
| コンソールに入る | `docker attach tus-minecraft` |
| OP付与 | `op 名前` / `/op 名前` |
| OP剥奪 | `deop 名前` / `/deop 名前` |
| ワールド一覧 | `/mv list` |
| ワールド作成 | `/mv create 名前 normal` |
| ワールド移動 | `/mvtp w:名前` |
| 荒らし調査 | `/co inspect` |
| 荒らしロールバック | `/co rollback user:名前 time:1h radius:50` |
| 権限確認 | `/lp user 名前 permission info` |
| グループ変更 | `/lp user 名前 parent set グループ名` |
| ワールド別移動権限付与 | `/lp group user permission set multiverse.teleport.self.w.ワールド名 true` |
| ホーム設定 | `/sethome` / `/home` |
| ワープ設定 | `/setwarp 名前`（OP） / `/warp 名前` |
| テレポートリクエスト | `/tpa 名前` → `/tpaccept` |
| 日本語変換オン/オフ | `/jp toggle` |
| Discord再読込 | `/discord reload` |
| TPS確認 | `/tps` |
| プレイヤー一覧 | `/list` |
| サーバー情報 | `/version` |
