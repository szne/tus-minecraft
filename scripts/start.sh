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
# 引数: <org/repo> <保存先パス> <アセット名に含まれる文字列>
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

    if [ -z "${url}" ]; then
        error "GitHub releases から ${repo} の URL が取得できませんでした（フィルタ: ${name_filter}）"
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
    if [ ! -f "${PLUGINS_DIR}/LuckPerms-Bukkit.jar" ]; then
        info "  [3/6] LuckPerms (権限管理)..."
        download_github_latest \
            "LuckPerms/LuckPerms" \
            "${PLUGINS_DIR}/LuckPerms-Bukkit.jar" \
            "Bukkit"
    else
        info "  [3/6] LuckPerms         → スキップ（既存）"
    fi

    # ④ DiscordSRV — Discord 双方向連携
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
    if [ ! -f "${PLUGINS_DIR}/CoreProtect.jar" ]; then
        info "  [5/6] CoreProtect (荒らし対策)..."
        download_github_latest \
            "PlayPro/CoreProtect" \
            "${PLUGINS_DIR}/CoreProtect.jar" \
            "CoreProtect"
    else
        info "  [5/6] CoreProtect       → スキップ（既存）"
    fi

    # ⑥ Multiverse-Core — マルチワールド（シーズン制アーカイブ）
    if [ ! -f "${PLUGINS_DIR}/Multiverse-Core.jar" ]; then
        info "  [6/6] Multiverse-Core (マルチワールド)..."
        download_github_latest \
            "Multiverse/Multiverse-Core" \
            "${PLUGINS_DIR}/Multiverse-Core.jar" \
            "Multiverse-Core"
    else
        info "  [6/6] Multiverse-Core   → スキップ（既存）"
    fi

    success "全プラグイン準備完了"
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

# ── DiscordSRV Bot Token の自動注入 ──────────────────────────
# サーバー初回起動後に DiscordSRV/config.yml が生成されたタイミングで反映
inject_discord_token() {
    local config="${PLUGINS_DIR}/DiscordSRV/config.yml"
    if [ -n "${DISCORD_BOT_TOKEN:-}" ] && [ -f "${config}" ]; then
        sed -i "s/^BotToken: .*/BotToken: \"${DISCORD_BOT_TOKEN}\"/" "${config}"
        info "  DiscordSRV: BotToken を環境変数から注入しました"
    elif [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
        warn "  DiscordSRV: config.yml 未生成のためトークン注入をスキップ"
        warn "  → サーバー初回起動→停止後に再起動すると自動注入されます"
    fi
}

# ── メイン処理 ───────────────────────────────────────────────
echo ""
# SERVER_DISPLAY_NAME 環境変数で表示名を変更可能（デフォルト: 下記）
SERVER_DISPLAY_NAME="${SERVER_DISPLAY_NAME:-東京理科大学 MCサークル（仮）}"

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

# DiscordSRV トークン注入
inject_discord_token

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
