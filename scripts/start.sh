#!/bin/bash
# ============================================================
# 東京理科大学マインクラフトサークル（仮）
# Paper Server 起動スクリプト
# ============================================================
# - Paper MC を自動ダウンロード（初回 & paper.jar がない場合）
# - 6つのプラグインを自動ダウンロード（未インストール分のみ）
# - EULA 自動承認
# - Aikar's JVM フラグで最適化起動
# ============================================================
set -euo pipefail

SERVER_DIR="/server"
CONFIG_TPL_DIR="/config-templates"
PLUGINS_DIR="${SERVER_DIR}/plugins"
MEMORY="${MEMORY:-4G}"

# ── カラー出力 ───────────────────────────────────────────────
info()    { echo -e "\033[1;36m[TUS-MC]\033[0m $*"; }
success() { echo -e "\033[1;32m[TUS-MC]\033[0m ✔ $*"; }
warn()    { echo -e "\033[1;33m[TUS-MC]\033[0m ⚠ $*"; }
error()   { echo -e "\033[1;31m[TUS-MC]\033[0m ✘ $*" >&2; }

# ── GitHub Releases から最新 jar をダウンロード ──────────────
# 引数: <org/repo> <保存先パス> <アセット名に含まれる文字列（大文字小文字区別あり）>
download_github_latest() {
    local repo="$1"
    local outfile="$2"
    local name_filter="$3"

    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local url
    url=$(curl -fsSL "${api_url}" \
        | jq -r --arg f "${name_filter}" \
          '.assets[] | select(.name | contains($f)) | .browser_download_url' \
        | head -1)

    if [ -z "${url}" ] || [ "${url}" = "null" ]; then
        error "GitHub releases から ${repo} の URL が取得できませんでした（フィルタ: ${name_filter}）"
        return 1
    fi

    info "    → ${url}"
    curl -fSL --progress-bar -o "${outfile}" "${url}"
}

# ── Modrinth から最新の安定版 jar をダウンロード ──────────────
# 引数: <project-slug> <保存先パス> [loader（省略時は全ローダー対象）]
# LuckPerms / CoreProtect / Multiverse-Core はGitHub Releasesが使えないため使用
download_modrinth_latest() {
    local slug="$1"
    local outfile="$2"
    local loader="${3:-}"  # 例: "bukkit", "paper" （省略で全ローダー対象）

    local api_url
    if [ -n "${loader}" ]; then
        # ローダーを指定してフィルタ（URL エンコード済み）
        api_url="https://api.modrinth.com/v2/project/${slug}/version?loaders=%5B%22${loader}%22%5D&limit=20"
    else
        api_url="https://api.modrinth.com/v2/project/${slug}/version?limit=20"
    fi

    local url
    # version_type=="release" のもののみ取得（alpha/beta/pre-release を除外）
    url=$(curl -fsSL "${api_url}" \
        | jq -r '[.[] | select(.version_type == "release")] | .[0].files[0].url')

    if [ -z "${url}" ] || [ "${url}" = "null" ]; then
        error "Modrinth から ${slug} (loader: ${loader:-any}) の URL が取得できませんでした"
        return 1
    fi

    info "    → ${url}"
    curl -fSL --progress-bar -o "${outfile}" "${url}"
}

# ── Paper MC ダウンロード ────────────────────────────────────
download_paper() {
    info "Paper MC をダウンロード中..."

    local version build jar_name
    # PAPER_VERSION 環境変数で固定可能。未設定なら自動で最新を取得。
    if [ -n "${PAPER_VERSION:-}" ]; then
        version="${PAPER_VERSION}"
        info "  バージョン固定: ${version}"
    else
        version=$(curl -fsSL https://api.papermc.io/v2/projects/paper \
            | jq -r '.versions[-1]')
    fi
    # channel は "STABLE" 等の大文字で返るためフィルタせず末尾（最新ビルド）を取得
    build=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}/builds" \
        | jq -r '.builds[-1].build')
    jar_name="paper-${version}-${build}.jar"

    info "  バージョン: ${version} / ビルド: ${build}"
    curl -fSL --progress-bar \
        -o "${SERVER_DIR}/paper.jar" \
        "https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}/downloads/${jar_name}"

    success "Paper ダウンロード完了 (${version} build ${build})"
}

# ── プラグインダウンロード ────────────────────────────────────
download_plugins() {
    mkdir -p "${PLUGINS_DIR}"
    info "プラグインをチェック・ダウンロード中..."

    # ① GeyserMC — Java/Bedrock クロスプレイ
    if [ ! -f "${PLUGINS_DIR}/Geyser-Spigot.jar" ]; then
        info "  [1/6] GeyserMC (クロスプレイ)..."
        curl -fSL --progress-bar \
            -o "${PLUGINS_DIR}/Geyser-Spigot.jar" \
            "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"
    else
        info "  [1/6] GeyserMC          → スキップ（既存）"
    fi

    # ② Floodgate — Bedrock プレイヤーの認証
    if [ ! -f "${PLUGINS_DIR}/floodgate-spigot.jar" ]; then
        info "  [2/6] Floodgate (BE認証)..."
        curl -fSL --progress-bar \
            -o "${PLUGINS_DIR}/floodgate-spigot.jar" \
            "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"
    else
        info "  [2/6] Floodgate         → スキップ（既存）"
    fi

    # ③ LuckPerms — 権限管理（Discord ロール連携の核）
    # GitHub Releases が空のため Modrinth から取得（bukkit ローダー指定で Bukkit 版を確実に取得）
    if [ ! -f "${PLUGINS_DIR}/LuckPerms-Bukkit.jar" ]; then
        info "  [3/6] LuckPerms (権限管理)..."
        download_modrinth_latest "luckperms" "${PLUGINS_DIR}/LuckPerms-Bukkit.jar" "bukkit"
    else
        info "  [3/6] LuckPerms         → スキップ（既存）"
    fi

    # ④ DiscordSRV — Discord 双方向連携
    # GitHub Releases が有効（アセット名: DiscordSRV-Build-x.x.x.jar）
    if [ ! -f "${PLUGINS_DIR}/DiscordSRV-Build.jar" ]; then
        info "  [4/6] DiscordSRV (Discord連携)..."
        download_github_latest \
            "DiscordSRV/DiscordSRV" \
            "${PLUGINS_DIR}/DiscordSRV-Build.jar" \
            "Build"
    else
        info "  [4/6] DiscordSRV        → スキップ（既存）"
    fi

    # ⑤ CoreProtect — 荒らし対策ログ・ロールバック
    # v22以降 GitHub Releases にアセットなし → Modrinth から取得
    if [ ! -f "${PLUGINS_DIR}/CoreProtect.jar" ]; then
        info "  [5/6] CoreProtect (荒らし対策)..."
        download_modrinth_latest "coreprotect" "${PLUGINS_DIR}/CoreProtect.jar"
    else
        info "  [5/6] CoreProtect       → スキップ（既存）"
    fi

    # ⑥ Multiverse-Core — マルチワールド（シーズン制アーカイブ）
    # GitHub のファイル名が全小文字（multiverse-core-x.x.x.jar）→ Modrinth で安定版を取得
    if [ ! -f "${PLUGINS_DIR}/Multiverse-Core.jar" ]; then
        info "  [6/6] Multiverse-Core (マルチワールド)..."
        download_modrinth_latest "multiverse-core" "${PLUGINS_DIR}/Multiverse-Core.jar"
    else
        info "  [6/6] Multiverse-Core   → スキップ（既存）"
    fi

    # ⑦ ViaVersion — GeyserMC が要求する Java バージョン互換レイヤー
    if [ ! -f "${PLUGINS_DIR}/ViaVersion.jar" ]; then
        info "  [7/8] ViaVersion (GeyserMC 互換)..."
        download_github_latest \
            "ViaVersion/ViaVersion" \
            "${PLUGINS_DIR}/ViaVersion.jar" \
            "ViaVersion-"
    else
        info "  [7/8] ViaVersion        → スキップ（既存）"
    fi

    # ⑧ JapanizeChat — ローマ字入力をリアルタイムで日本語に変換
    if [ ! -f "${PLUGINS_DIR}/JapanizeChat.jar" ]; then
        info "  [8/8] JapanizeChat (ローマ字→日本語)..."
        download_modrinth_latest "japanizechat" "${PLUGINS_DIR}/JapanizeChat.jar"
    else
        info "  [8/8] JapanizeChat      → スキップ（既存）"
    fi

    success "全プラグイン準備完了"
}

# ── バンドルプラグインのコピー ────────────────────────────────
# Docker イメージにビルド済みで同梱されているプラグインを plugins/ に配置
# （JapanizeDiscordBridge: JapanizeChat ↔ DiscordSRV 日本語ブリッジ）
copy_bundled_plugins() {
    local bundled_dir="/bundled-plugins"
    if [ ! -d "${bundled_dir}" ]; then
        return
    fi

    for jar in "${bundled_dir}"/*.jar; do
        [ -f "${jar}" ] || continue
        local fname
        fname=$(basename "${jar}")
        # 常に上書きコピー（Docker再ビルド時にプラグインを更新するため）
        cp -f "${jar}" "${PLUGINS_DIR}/${fname}"
        info "  バンドルプラグイン: ${fname}"
    done
}

# ── 初回セットアップ ─────────────────────────────────────────
first_run_setup() {
    info "初回セットアップを実行中..."

    # EULA 自動承認（Minecraft 利用規約に同意）
    echo "eula=true" > "${SERVER_DIR}/eula.txt"
    info "  EULA を承認しました"

    # server.properties テンプレートをコピー
    if [ ! -f "${SERVER_DIR}/server.properties" ] \
       && [ -f "${CONFIG_TPL_DIR}/server.properties" ]; then
        cp "${CONFIG_TPL_DIR}/server.properties" "${SERVER_DIR}/server.properties"
        info "  server.properties をテンプレートからコピーしました"
    fi

    # 初期化済みフラグを記録
    date -Iseconds > "${SERVER_DIR}/.initialized"
    success "初回セットアップ完了"
}

# ── デフォルトワールド設定の注入 ─────────────────────────────
# DEFAULT_WORLD 環境変数で server.properties と bukkit.yml を同時に更新
# 用途例: world を mv regen したいとき → DEFAULT_WORLD=lobby に設定して再起動
inject_world_config() {
    local world="${DEFAULT_WORLD:-world}"

    # server.properties: level-name
    if [ -f "${SERVER_DIR}/server.properties" ]; then
        sed -i "s/^level-name=.*/level-name=${world}/" "${SERVER_DIR}/server.properties"
        info "  level-name → ${world}"
    fi

    # bukkit.yml: default-world-name（存在すれば更新、なければ settings: 直下に追加）
    local bukkit="${SERVER_DIR}/bukkit.yml"
    if [ -f "${bukkit}" ]; then
        if grep -q "default-world-name:" "${bukkit}"; then
            sed -i "s/^  default-world-name:.*/  default-world-name: ${world}/" "${bukkit}"
        else
            sed -i "s/^settings:/settings:\n  default-world-name: ${world}/" "${bukkit}"
        fi
        info "  default-world-name → ${world}"
    fi
}

# ── DiscordSRV 設定の自動注入 ────────────────────────────────
# サーバー初回起動後に DiscordSRV/config.yml が生成されたタイミングで反映
# 対象: DISCORD_BOT_TOKEN / DISCORD_CHANNEL_ID
inject_discord_config() {
    local config="${PLUGINS_DIR}/DiscordSRV/config.yml"

    if [ ! -f "${config}" ]; then
        warn "  DiscordSRV: config.yml 未生成のため注入をスキップ"
        warn "  → サーバー初回起動→停止後に再起動すると自動注入されます"
        return
    fi

    if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
        sed -i "s/^BotToken: .*/BotToken: \"${DISCORD_BOT_TOKEN}\"/" "${config}"
        info "  DiscordSRV: BotToken を注入しました"
    fi

    if [ -n "${DISCORD_CHANNEL_ID:-}" ]; then
        # DiscordSRV の実際の書式: Channels: {"global": "000000000000000000"}
        sed -i "s/\"global\": \"[0-9]*\"/\"global\": \"${DISCORD_CHANNEL_ID}\"/" "${config}"
        info "  DiscordSRV: チャンネルID (global) を注入しました → ${DISCORD_CHANNEL_ID}"
    fi

    # Webhook モードでプレイヤーのスキンアイコンを Discord に表示
    # AvatarUrl に crafatar.com を設定し、Webhook 配信を有効化
    sed -i "s/^Experiment_WebhookChatMessageDelivery: false/Experiment_WebhookChatMessageDelivery: true/" "${config}"
    sed -i "s|^AvatarUrl: .*|AvatarUrl: \"https://crafatar.com/avatars/{uuid}?size=128\&overlay\"|" "${config}"
    info "  DiscordSRV: Webhook アバター表示を有効化しました"

    # JapanizeChat は Paper 新式の AsyncChatEvent を使用するため、
    # DiscordSRV も同じイベントを読むよう切り替え（これにより変換後の日本語がDiscordに届く）
    sed -i "s/^UseModernPaperChatEvent: false/UseModernPaperChatEvent: true/" "${config}"
    info "  DiscordSRV: UseModernPaperChatEvent を有効化しました（JapanizeChat 連携）"
}

# ── メイン処理 ───────────────────────────────────────────────
echo ""
# SERVER_DISPLAY_NAME 環境変数で表示名を変更可能（デフォルト: 下記）
SERVER_DISPLAY_NAME="${SERVER_DISPLAY_NAME:-理科大マイクラ部}"

echo "  ╔══════════════════════════════════════╗"
echo "  ║  ${SERVER_DISPLAY_NAME}"
echo "  ║  Paper Server Starting..."
echo "  ║  Memory: ${MEMORY}"
echo "  ╚══════════════════════════════════════╝"
echo ""

cd "${SERVER_DIR}"

# 初回チェック
if [ ! -f "${SERVER_DIR}/.initialized" ]; then
    first_run_setup
fi

# Paper がなければダウンロード
if [ ! -f "${SERVER_DIR}/paper.jar" ]; then
    download_paper
fi

# プラグインダウンロード（未インストール分のみ）
download_plugins

# バンドルプラグインをコピー
copy_bundled_plugins

# デフォルトワールド設定注入
inject_world_config

# DiscordSRV 設定注入（BotToken・チャンネルID）
inject_discord_config

# ── JVM フラグ（Aikar's Flags for Java 21 + G1GC）────────────
# 参考: https://docs.papermc.io/paper/aikars-flags
JVM_FLAGS=(
    "-Xms${MEMORY}"
    "-Xmx${MEMORY}"
    "-XX:+UseG1GC"
    "-XX:+ParallelRefProcEnabled"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+DisableExplicitGC"
    "-XX:+AlwaysPreTouch"
    "-XX:G1NewSizePercent=30"
    "-XX:G1MaxNewSizePercent=40"
    "-XX:G1HeapRegionSize=8M"
    "-XX:G1ReservePercent=20"
    "-XX:G1HeapWastePercent=5"
    "-XX:G1MixedGCCountTarget=4"
    "-XX:InitiatingHeapOccupancyPercent=15"
    "-XX:G1MixedGCLiveThresholdPercent=90"
    "-XX:G1RSetUpdatingPauseTimePercent=5"
    "-XX:SurvivorRatio=32"
    "-XX:+PerfDisableSharedMem"
    "-XX:MaxTenuringThreshold=1"
    "-Dusing.aikars.flags=https://mcflags.emc.gs"
    "-Daikars.new.flags=true"
    "-Dfile.encoding=UTF-8"
)

info "Java 起動コマンド: java [Aikar's Flags] -jar paper.jar --nogui"
echo ""

# exec で Java を PID 1 に置き換え（SIGTERM を正しく受け取るため）
exec java "${JVM_FLAGS[@]}" -jar "${SERVER_DIR}/paper.jar" --nogui
