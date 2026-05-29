#!/usr/bin/env bash
# ============================================================
# ワールド初期設定スクリプト（RCON 経由）
# 初回または再構築後に1回だけ実行する
#
# 前提: RCON が有効化されていること（enable-rcon=true）
# 実行: ssh bonsai "~/Container/tus-minecraft/scripts/setup-worlds.sh"
# ============================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# .env から RCON_PASSWORD を読み込む
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' "${ENV_FILE}" | grep -v '^$' | xargs)
fi

RCON_HOST="localhost"
RCON_PORT="25575"
RCON_PASS="${RCON_PASSWORD:-}"

if [ -z "${RCON_PASS}" ] || [ "${RCON_PASS}" = "changeme" ]; then
    echo "ERROR: RCON_PASSWORD が .env に設定されていません。"
    exit 1
fi

# mcrcon がなければインストール
if ! command -v mcrcon &>/dev/null; then
    echo "mcrcon をインストール中..."
    brew install mcrcon
fi

rcon() {
    mcrcon -H "${RCON_HOST}" -P "${RCON_PORT}" -p "${RCON_PASS}" "$1"
}

echo "=== ワールド初期設定開始 ==="

# ── gamerule: スリープ投票（50%以上が寝ると夜が明ける）──────
echo "[1/4] playersSleepingPercentage を設定中..."
rcon "execute in minecraft:season2026 run gamerule playersSleepingPercentage 50"
rcon "execute in minecraft:test run gamerule playersSleepingPercentage 50"

# ── MyWorlds ポータルリンク ───────────────────────────────────
echo "[2/4] MyWorlds ポータルリンクを設定中..."
rcon "myworlds world season2026 setnetherworld season2026_nether"
rcon "myworlds world season2026 setendworld season2026_the_end"
rcon "myworlds world test setnetherworld test_nether"
rcon "myworlds world test setendworld test_the_end"

# ── Multiverse-Core デバッグモード無効化 ─────────────────────
echo "[3/4] Multiverse デバッグモードを無効化中..."
rcon "mv config global-debug 0"
rcon "mv reload"

# ── 確認 ─────────────────────────────────────────────────────
echo "[4/4] ワールド一覧確認..."
rcon "mv list"

echo "=== ワールド初期設定完了 ==="
echo ""
echo "次のステップ:"
echo "  - season2026 に入り /gamerule を確認"
echo "  - ネザーポータルが season2026_nether に飛ぶことを確認"
