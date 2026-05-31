#!/usr/bin/env bash
# ============================================================
# tus-minecraft 即時再起動スクリプト
# 手動でサーバーを再起動したいときに使用
#
# 実行フロー:
#   0:00  - 1分前警告（RCON経由で全ワールドに配信）
#   0:50  - 10秒前カウントダウン
#   1:00  - バックアップ → 再起動
#   起動後 - RCON 経由で自動セットアップ（MVNP, gamerule など）
# ============================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export DOCKER_HOST="unix://${HOME}/.orbstack/run/docker.sock"

CONTAINER="tus-minecraft"
BACKUP_DIR="${HOME}/Container/tus-minecraft-backups"
DATA_DIR="${HOME}/Container/tus-minecraft/data"
MAX_BACKUPS=7
DATE=$(date '+%Y%m%d-%H%M')
LOGFILE="${BACKUP_DIR}/restart.log"

mkdir -p "${BACKUP_DIR}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOGFILE}"; }

is_running() {
    docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true
}

# ── RCON セットアップ ─────────────────────────────────────
ENV_FILE="${HOME}/Container/tus-minecraft/.env"
RCON_PASS=""
if [ -f "${ENV_FILE}" ]; then
    RCON_PASS=$(grep '^RCON_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)
fi
MCRCON="${HOME}/bin/mcrcon"

rcon_cmd() {
    "${MCRCON}" -H localhost -P 25575 -p "${RCON_PASS}" "$1" 2>/dev/null
}

rcon_broadcast() {
    if [ -n "${RCON_PASS}" ] && [ "${RCON_PASS}" != "changeme" ]; then
        rcon_cmd "broadcast $1" || true
    fi
}

wait_for_rcon() {
    local attempts=0
    while [ ${attempts} -lt 30 ]; do
        if rcon_cmd "list" &>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 10
    done
    return 1
}

log "========================================"
log " 即時再起動シーケンス開始"
log "========================================"

if ! is_running; then
    log "WARNING: コンテナが起動していません。スキップ。"
    exit 0
fi

# ── 1分前警告（RCON 経由で全ワールドに配信）──────────────
log "T-1分 警告送信..."
rcon_broadcast "&c&l[メンテナンス]&r &f1分後にサーバーを再起動します。安全な場所へ移動してください。"
sleep 50

log "T-10秒 カウントダウン送信..."
rcon_broadcast "&c&l[メンテナンス]&r &c10秒後に再起動します..."
sleep 5
rcon_broadcast "&c&l[メンテナンス]&r &c5秒前..."
sleep 3
rcon_broadcast "&c&l[メンテナンス]&r &c2秒前..."
sleep 1
rcon_broadcast "&c&l[メンテナンス]&r &c1秒前..."
sleep 1
rcon_broadcast "&c&l[メンテナンス]&r &f再起動します。すぐに再接続できます！"
sleep 2

# ── バックアップ ──────────────────────────────────────────
log "バックアップ開始..."
if tar -czf "${BACKUP_DIR}/backup-${DATE}.tar.gz" \
    -C "${HOME}/Container/tus-minecraft" \
    --exclude="data/logs" \
    --exclude="data/cache" \
    data 2>/dev/null; then
    log "バックアップ完了: backup-${DATE}.tar.gz"
else
    log "WARNING: バックアップでエラーが発生しましたが再起動を続行します"
fi

ls -t "${BACKUP_DIR}"/backup-*.tar.gz 2>/dev/null \
    | tail -n +$((MAX_BACKUPS + 1)) \
    | xargs rm -f 2>/dev/null || true

# ── 再起動 ───────────────────────────────────────────────
# docker compose up -d --force-recreate を使うことで
# .env の変更（DEFAULT_WORLD 等）を毎回確実に反映する
COMPOSE_DIR="${HOME}/Container/tus-minecraft"
log "docker compose up -d --force-recreate minecraft を実行..."
(cd "${COMPOSE_DIR}" && docker compose up -d --force-recreate minecraft)
log "再起動コマンド完了。サーバー起動を待機中..."

# ── 起動後セットアップ（RCON 経由）────────────────────────
if [ -n "${RCON_PASS}" ] && [ "${RCON_PASS}" != "changeme" ]; then
    log "RCON 接続待機中（最大 300 秒）..."
    if wait_for_rcon; then
        log "RCON 接続成功。"

        # ── 一回限りの移行処理: test → 2026end ───────────────
        if [ -d "${DATA_DIR}/test" ] && [ ! -d "${DATA_DIR}/2026end" ]; then
            log "test → 2026end のリネーム処理を実行中..."
            cp -r "${DATA_DIR}/test" "${DATA_DIR}/2026end"
            rm -f "${DATA_DIR}/2026end/uid.dat"
            sleep 2
            rcon_cmd "mv unload test_the_end"
            sleep 3
            rcon_cmd "mv unload test_nether"
            sleep 3
            rcon_cmd "mv unload test"
            sleep 8
            rcon_cmd "mv remove test_the_end"
            sleep 2
            rcon_cmd "mv remove test_nether"
            sleep 2
            rcon_cmd "mv remove test"
            sleep 2
            rcon_cmd "mv import 2026end normal"
            sleep 8
            rm -rf "${DATA_DIR}/test"
            rm -rf "${DATA_DIR}/test_nether"
            rm -rf "${DATA_DIR}/test_the_end"
            rcon_cmd "mvinv reload"
            log "✓ test → 2026end リネーム完了"
        fi

        # ── Multiverse-NetherPortals リロード ────────────────
        rcon_cmd "mvnp reload"
        log "✓ Multiverse-NetherPortals リロード完了"

        # ── スリープ投票（50%）───────────────────────────────
        rcon_cmd "execute in minecraft:season2026 run gamerule playersSleepingPercentage 50"
        rcon_cmd "execute in minecraft:2026end run gamerule playersSleepingPercentage 50"
        rcon_cmd "execute in minecraft:2026end2 run gamerule playersSleepingPercentage 50"
        log "✓ playersSleepingPercentage 設定完了"

        # ── Multiverse デバッグモード無効化 ──────────────────
        rcon_cmd "mv config global-debug 0"
        rcon_cmd "mv reload"
        log "✓ Multiverse デバッグモード無効化完了"
    else
        log "WARNING: RCON が起動しませんでした。手動で確認してください。"
    fi
else
    log "WARNING: RCON_PASSWORD 未設定のためセットアップをスキップ"
fi

# ── LuckPerms パーミッション設定（docker attach 経由）─────────
SETUP_SCRIPT="${HOME}/Container/tus-minecraft/scripts/setup-permissions.sh"
if [ -f "${SETUP_SCRIPT}" ]; then
    log "LuckPerms パーミッション設定中..."
    bash "${SETUP_SCRIPT}" && log "✓ LuckPerms パーミッション設定完了" \
        || log "WARNING: パーミッション設定でエラー（手動で setup-permissions.sh を実行）"
fi

log "========================================"
log " 即時再起動シーケンス終了"
log "========================================"
