#!/usr/bin/env bash
# ============================================================
# LuckPerms パーミッション設定スクリプト
# RCON では LuckPerms コマンドが効かないため docker attach 経由で送信する
#
# 使い方:
#   bash ~/Container/tus-minecraft/scripts/setup-permissions.sh
# ============================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export DOCKER_HOST="unix://${HOME}/.orbstack/run/docker.sock"

CONTAINER="tus-minecraft"
LOGFILE="${HOME}/Container/tus-minecraft-backups/restart.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOGFILE}"; }

run_lp_commands() {
python3 - <<'PYEOF'
import subprocess, tempfile, os

commands = [
    # ── member グループ ───────────────────────────────────────
    # /back コマンド（死亡・TP後の位置に戻る）
    'lp group member permission set essentials.back true',
    # 死亡時アイテムキープ
    'lp group member permission set essentials.keepinventory true',
    # Multiverse-Core 5.x: use-finer-teleport-permissions=true のため
    # ワールド個別権限が必要（ワイルドカードで全ワールドへのTP許可）
    'lp group member permission set multiverse.teleport.self.w.* true',

    # ── tus.unverified の否定（admin/* ワイルドカード対策）───────
    # admin/* で tus.unverified が true になるのを明示的に否定する
    'lp group admin permission set tus.unverified false',
    'lp group staff permission set tus.unverified false',
    'lp group member permission set tus.unverified false',
    'lp group tourist permission set tus.unverified false',
]

lines = [
    'log_user 1',
    'set timeout 30',
    'spawn docker attach --detach-keys=ctrl-p,ctrl-q tus-minecraft',
    'sleep 0.8',
]
for cmd in commands:
    esc = cmd.replace('"', r'\"')
    lines.append('send "' + esc + r'\r"')
    lines.append('sleep 1.5')
lines += [r'send "\x10\x11"', 'expect eof']

with tempfile.NamedTemporaryFile('w', suffix='.exp', delete=False, encoding='utf-8') as f:
    f.write('\n'.join(lines))
    name = f.name

result = subprocess.run(['expect', name], capture_output=True, text=True, timeout=90)
os.unlink(name)

# 成功確認
if 'Set' in result.stdout and 'true' in result.stdout:
    print('✓ パーミッション設定完了')
else:
    print('設定出力:', result.stdout[-1000:])
PYEOF
}

log "========================================"
log " パーミッション設定スクリプト開始"
log "========================================"

# コンテナ起動確認
if ! docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true; then
    log "ERROR: コンテナが起動していません"
    exit 1
fi

log "LuckPerms コマンド送信中..."
run_lp_commands
log "========================================"
log " パーミッション設定完了"
log "========================================"
