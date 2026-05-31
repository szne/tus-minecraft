package me.tus.japanizechat;

import io.papermc.paper.event.player.AsyncChatEvent;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;
import net.kyori.adventure.text.serializer.legacy.LegacyComponentSerializer;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import net.milkbowl.vault.chat.Chat;
import org.bukkit.Bukkit;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.block.BlockBreakEvent;
import org.bukkit.event.block.BlockPlaceEvent;
import org.bukkit.event.player.PlayerCommandPreprocessEvent;
import org.bukkit.plugin.RegisteredServiceProvider;
import org.bukkit.plugin.java.JavaPlugin;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * JapanizeDiscordBridge
 *
 * - ローマ字→日本語変換（Google Input Tools API）
 * - Vault 経由で LuckPerms プレフィックスをチャットに表示
 * - Discord 送信にも変換結果を反映
 * - BuildGuard: tus.build 権限のないプレイヤーの建築ブロック
 *
 * チャット表示形式: [プレフィックス] 名前 » メッセージ (日本語変換)
 */
public final class JapanizeDiscordBridge extends JavaPlugin implements Listener {

    private static final String GOOGLE_API_URL =
            "https://inputtools.google.com/request?text=%s&itc=ja-t-i0-und&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8&app=demopage";

    /** ASCII ローマ字と基本的な記号のみを変換対象にする */
    private static final Pattern ROMAJI_PATTERN =
            Pattern.compile("^[\\x20-\\x7E]+$");

    /** /msg, /tell, /w, /m <相手> <メッセージ> */
    private static final Pattern MSG_CMD_PATTERN =
            Pattern.compile("^/(msg|tell|w|m)\\s+(\\S+)\\s+(.+)$", Pattern.CASE_INSENSITIVE);
    /** /r, /reply <メッセージ> */
    private static final Pattern REPLY_CMD_PATTERN =
            Pattern.compile("^/(r|reply)\\s+(.+)$", Pattern.CASE_INSENSITIVE);

    /** 変換処理中のプレイヤー（無限ループ防止） */
    private final Set<UUID> processing = Collections.synchronizedSet(new HashSet<>());

    private HttpClient httpClient;

    /** Vault Chat サービス（プレフィックス取得） */
    private Chat vaultChat = null;

    /** Discord 認証済みプレイヤーだけが持つ建築許可ノード */
    private static final String BUILD_PERMISSION = "tus.build";

    @Override
    public void onEnable() {
        httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build();

        // Vault Chat サービスを取得
        if (getServer().getPluginManager().getPlugin("Vault") != null) {
            RegisteredServiceProvider<Chat> rsp =
                    getServer().getServicesManager().getRegistration(Chat.class);
            if (rsp != null) {
                vaultChat = rsp.getProvider();
                getLogger().info("Vault Chat サービス取得成功 — チャットプレフィックスを有効化");
            } else {
                getLogger().warning("Vault Chat サービスが見つかりません（LuckPerms が起動しているか確認）");
            }
        } else {
            getLogger().warning("Vault が見つかりません — プレフィックスなしで動作します");
        }

        getServer().getPluginManager().registerEvents(this, this);
        getLogger().info("JapanizeDiscordBridge 有効化 — ゲーム内・Discord・/msg 全てに日本語変換を適用します");
        getLogger().info("BuildGuard 有効化 — tus.build 権限のないプレイヤーの建築をブロックします");
    }

    // ---------------------------------------------------------------
    // BuildGuard: Discord 未認証プレイヤーの建築・破壊をブロック
    // ---------------------------------------------------------------

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onBlockBreak(BlockBreakEvent event) {
        if (!event.getPlayer().hasPermission(BUILD_PERMISSION)) {
            event.setCancelled(true);
            event.getPlayer().sendMessage(
                Component.text("§e/discord link §fで Discord 認証を行うと建築できるようになります"));
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onBlockPlace(BlockPlaceEvent event) {
        if (!event.getPlayer().hasPermission(BUILD_PERMISSION)) {
            event.setCancelled(true);
            event.getPlayer().sendMessage(
                Component.text("§e/discord link §fで Discord 認証を行うと建築できるようになります"));
        }
    }

    // ---------------------------------------------------------------
    // PrivateMsgConverter: /msg /tell /w /m /r /reply でも日本語変換
    // ---------------------------------------------------------------

    @EventHandler(priority = EventPriority.HIGHEST, ignoreCancelled = true)
    public void onPrivateMessage(PlayerCommandPreprocessEvent event) {
        Player player = event.getPlayer();
        UUID uuid = player.getUniqueId();

        if (processing.contains(uuid)) return;

        String raw = event.getMessage();
        java.util.regex.Matcher msgMatcher   = MSG_CMD_PATTERN.matcher(raw);
        java.util.regex.Matcher replyMatcher = REPLY_CMD_PATTERN.matcher(raw);

        final String baseCmd;
        final String msgText;

        if (msgMatcher.matches()) {
            baseCmd = "/" + msgMatcher.group(1) + " " + msgMatcher.group(2) + " ";
            msgText = msgMatcher.group(3);
        } else if (replyMatcher.matches()) {
            baseCmd = "/" + replyMatcher.group(1) + " ";
            msgText = replyMatcher.group(2);
        } else {
            return;
        }

        if (!ROMAJI_PATTERN.matcher(msgText).matches()) return;

        event.setCancelled(true);
        processing.add(uuid);

        Bukkit.getScheduler().runTaskAsynchronously(this, () -> {
            String japanese = convertToJapanese(msgText);
            String finalMsg = (japanese != null && !japanese.isEmpty() && !japanese.equals(msgText))
                    ? msgText + " (" + japanese + ")"
                    : msgText;

            Bukkit.getScheduler().runTask(this, () -> {
                try {
                    player.performCommand((baseCmd + finalMsg).replaceFirst("^/", ""));
                } finally {
                    processing.remove(uuid);
                }
            });
        });
    }

    // ---------------------------------------------------------------
    // ChatFormatter: プレフィックス表示 + ローマ字→日本語変換
    // ---------------------------------------------------------------

    /**
     * MONITOR 優先度で AsyncChatEvent を処理。
     *
     * 全メッセージ共通:
     *   [プレフィックス] 名前 » メッセージ
     *
     * ローマ字入力の場合のみ追加:
     *   [プレフィックス] 名前 » ローマ字 (日本語)
     */
    @EventHandler(priority = EventPriority.MONITOR)
    public void onChat(AsyncChatEvent event) {
        String romaji = PlainTextComponentSerializer.plainText()
                .serialize(event.message());

        // ローマ字変換が可能な場合
        if (!romaji.isBlank() && ROMAJI_PATTERN.matcher(romaji).matches()) {
            String japanese = convertToJapanese(romaji);
            if (japanese != null && !japanese.isEmpty() && !japanese.equals(romaji)) {
                final Component romajiComponent = event.message();
                final Component japaneseAnnotation = Component.text(" (" + japanese + ")")
                        .color(NamedTextColor.GRAY);

                // ゲーム内表示: [prefix] 名前 » ローマ字 (日本語)
                event.renderer((source, displayName, message, viewer) ->
                    buildPrefix(source)
                        .append(displayName)
                        .append(Component.text(" » "))
                        .append(romajiComponent)
                        .append(japaneseAnnotation)
                );

                // Discord 用: ローマ字 (日本語) を message に設定
                event.message(Component.text(romaji + " (" + japanese + ")"));
                return;
            }
        }

        // 日本語直打ち・英語など変換なし: [prefix] 名前 » メッセージ
        event.renderer((source, displayName, message, viewer) ->
            buildPrefix(source)
                .append(displayName)
                .append(Component.text(" » "))
                .append(message)
        );
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /**
     * Vault Chat からプレフィックスを取得して Adventure Component に変換する。
     * Vault が未ロードの場合は空 Component を返す。
     *
     * LuckPerms は §a[スタッフ] のようなセクション記号付き文字列を返すので
     * LegacyComponentSerializer.legacySection() でデシリアライズする。
     */
    private Component buildPrefix(Player player) {
        if (vaultChat == null) return Component.empty();
        String prefix = vaultChat.getPlayerPrefix(player);
        if (prefix == null || prefix.isEmpty()) return Component.empty();
        return LegacyComponentSerializer.legacyAmpersand().deserialize(prefix);
    }

    /**
     * Google Input Tools API でローマ字を日本語に変換する。
     */
    private String convertToJapanese(String romaji) {
        try {
            String encoded = URLEncoder.encode(romaji, StandardCharsets.UTF_8);
            String url = String.format(GOOGLE_API_URL, encoded);

            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofSeconds(3))
                    .header("User-Agent", "Mozilla/5.0")
                    .GET()
                    .build();

            HttpResponse<String> resp = httpClient.send(req,
                    HttpResponse.BodyHandlers.ofString());

            return parseGoogleResponse(resp.body());
        } catch (Exception e) {
            getLogger().fine("Google API 変換失敗 (無視): " + e.getMessage());
            return null;
        }
    }

    /**
     * Google Input Tools API のレスポンスを解析し、第一候補の日本語文字列を返す。
     */
    private String parseGoogleResponse(String json) {
        if (json == null || !json.contains("SUCCESS")) return null;
        try {
            int pos = 0;
            int open1 = json.indexOf('"', pos);
            if (open1 < 0) return null;
            int close1 = json.indexOf('"', open1 + 1);
            if (close1 < 0) return null;
            pos = close1 + 1;

            int open2 = json.indexOf('"', pos);
            if (open2 < 0) return null;
            int close2 = json.indexOf('"', open2 + 1);
            if (close2 < 0) return null;
            pos = close2 + 1;

            int open3 = json.indexOf('"', pos);
            if (open3 < 0) return null;
            int close3 = json.indexOf('"', open3 + 1);
            if (close3 < 0) return null;

            String candidate = json.substring(open3 + 1, close3);
            return candidate.isEmpty() ? null : candidate;
        } catch (Exception e) {
            getLogger().fine("レスポンス解析失敗: " + e.getMessage());
        }
        return null;
    }
}
