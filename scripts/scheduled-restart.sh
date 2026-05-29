#!/usr/bin/env bash
# ============================================================
# tus-minecraft 定期再起動スクリプト
# 毎日 3:00 に cron から実行（bonsai 上で動作）
#
# 実行タイミング:
#   3:00  - 10分前警告
#   3:05  - 5分前警告
#   3:09  - 1分前警告
#   3:10  - バックアップ → 再起動
# ============================================================
set -euo pipefail

# ── macOS cron 向け PATH 補完 ─────────────────────────────
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

# ── コンテナが起動中か確認 ────────────────────────────────
is_running() {
    docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true
}

# ── Minecraftサーバーにコマンド送信（expect経由）────────────
mc_cmd() {
    local cmd="$1"
    is_running || return 0
    expect -c "
        log_user 0
        set timeout 8
        spawn docker attach --detach-keys=ctrl-p,ctrl-q ${CONTAINER}
        sleep 0.5
        send \"${cmd}\r\"
        sleep 1.5
        send \x10\x11
        expect eof
    " 2>/dev/null || true
}

# ── ブロードキャストメッセージ送信 ────────────────────────
mc_broadcast() {
    mc_cmd "broadcast $1"
}

# ── メイン処理 ────────────────────────────────────────────
log "========================================"
log " 定期再起動シーケンス開始"
log "========================================"

if ! is_running; then
    log "WARNING: コンテナが起動していません。スキップ。"
    exit 0
fi

# ── カウントダウン警告 ────────────────────────────────────
log "T-10分 警告送信..."
mc_broadcast "&e&l[定期メンテナンス]&r &f毎日3時の定期再起動まで &e&l10分&r&fです。進行中の作業を保存してください。"
sleep 300   # 5分待機

log "T-5分 警告送信..."
mc_broadcast "&e&l[定期メンテナンス]&r &f再起動まで &e&l5分&r&fです。安全な場所へ移動してください。"
sleep 240   # 4分待機

log "T-1分 警告送信..."
mc_broadcast "&c&l[定期メンテナンス]&r &f再起動まで &c&l1分&r&fです！"
sleep 50    # 50秒待機

# 10秒前カウントダウン（1セッションで送信）
log "T-10秒 カウントダウン送信..."
is_running && expect -c "
    log_user 0
    set timeout 30
    spawn docker attach --detach-keys=ctrl-p,ctrl-q ${CONTAINER}
    sleep 0.5
    send \"broadcast &c&l[定期メンテナンス]&r &c10秒後に再起動します...\r\"
    sleep 5
    send \"broadcast &c&l[定期メンテナンス]&r &c5秒前...\r\"
    sleep 3
    send \"broadcast &c&l[定期メンテナンス]&r &c2秒前...\r\"
    sleep 1
    send \"broadcast &c&l[定期メンテナンス]&r &c1秒前...\r\"
    sleep 1
    send \"broadcast &c&l[定期メンテナンス]&r &c§f再起動します。すぐに再接続できます！\r\"
    sleep 1
    send \x10\x11
    expect eof
" 2>/dev/null || true

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

# 古いバックアップを削除（MAX_BACKUPS 件を超えた分）
ls -t "${BACKUP_DIR}"/backup-*.tar.gz 2>/dev/null \
    | tail -n +$((MAX_BACKUPS + 1)) \
    | xargs rm -f 2>/dev/null || true

# ── 再起動 ───────────────────────────────────────────────
log "docker restart ${CONTAINER} を実行..."
docker restart "${CONTAINER}"
log "再起動コマンド完了。"

log "========================================"
log " 定期再起動シーケンス終了"
log "========================================"
