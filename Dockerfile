# ============================================================
# 東京理科大学マインクラフトサークル（仮）
# Paper Minecraft Server - Dockerfile
# ============================================================
# eclipse-temurin:21 は linux/amd64 & linux/arm64 両対応
# → M1 Mac でも VPS (x86_64) でもそのまま動作
# ============================================================

# ── ステージ1: JapanizeDiscordBridge プラグインをコンパイル ──
# JapanizeChat（ChatRenderer）→ DiscordSRV（event.message）のブリッジ
FROM maven:3.9-eclipse-temurin-21 AS bridge-build
WORKDIR /build
COPY bridge-plugin/pom.xml .
# 依存関係を先にダウンロード（Dockerキャッシュ最適化）
RUN mvn dependency:go-offline -q
COPY bridge-plugin/src ./src
RUN mvn package -q -DskipTests

# ── ステージ2: 本番イメージ ───────────────────────────────────
FROM eclipse-temurin:21-jre-jammy

LABEL maintainer="TUS Minecraft Circle"
LABEL description="東京理科大学マインクラフトサークル Paper Server (Java + Bedrock対応)"

# ── ユーティリティのインストール ─────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl \
       jq \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── 専用ユーザー作成（rootで動かさない） ─────────────────────
RUN groupadd -g 1000 minecraft \
    && useradd -m -u 1000 -g 1000 -s /bin/bash minecraft

# ── サーバーデータディレクトリ（ボリュームとしてマウント） ────
RUN mkdir -p /server && chown minecraft:minecraft /server

# ── 設定テンプレート（初回起動時に /server へコピー） ────────
COPY --chown=minecraft:minecraft config/ /config-templates/

# ── バンドルプラグイン（ビルドステージからコピー） ────────────
# JapanizeDiscordBridge: JapanizeChat ↔ DiscordSRV 日本語ブリッジ
RUN mkdir -p /bundled-plugins
COPY --from=bridge-build --chown=minecraft:minecraft \
    /build/target/JapanizeDiscordBridge.jar /bundled-plugins/

# ── 起動スクリプト ────────────────────────────────────────────
COPY --chown=minecraft:minecraft scripts/start.sh /start.sh
RUN chmod +x /start.sh

WORKDIR /server
USER minecraft

# Java Edition
EXPOSE 25565/tcp
# Bedrock Edition (GeyserMC)
EXPOSE 19132/udp

# 起動後180秒猶予を与えてヘルスチェック
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD bash -c 'echo "" | timeout 3 bash -c "cat < /dev/tcp/localhost/25565" 2>/dev/null || exit 1'

ENTRYPOINT ["/start.sh"]
