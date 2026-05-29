package me.tus.japanizechat;

import io.papermc.paper.chat.ChatRenderer;
import io.papermc.paper.event.player.AsyncChatEvent;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import org.bukkit.Bukkit;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.block.BlockBreakEvent;
import org.bukkit.event.block.BlockPlaceEvent;
import org.bukkit.event.player.PlayerCommandPreprocessEvent;
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
 * Google Input Tools API でローマ字→日本語変換を行い、
 * ゲーム内表示と Discord 送信の両方に同じ変換結果を適用する。
 *
 * ゲーム内: 「ローマ字 (日本語)」形式で表示（JapanizeChat の renderer を上書き）
 * Discord : 「ローマ字 (日本語)」形式で DiscordSRV に渡す
 */
public final class JapanizeDiscordBridge extends JavaPlugin implements Listener {

    private static final String GOOGLE_API_URL =
            "https://inputtools.google.com/request?text=%s&itc=ja-t-i0-und&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8&app=demopage";

    // ASCII ローマ字と基本的な記号のみを対象とする（日本語はスキップ）
    private static final Pattern ROMAJI_PATTERN =
            Pattern.compile("^[\\x20-\\x7E]+$");

    // /msg, /tell, /w, /m + 相手名 + スペース + メッセージ本文
    private static final Pattern MSG_CMD_PATTERN =
            Pattern.compile("^/(msg|tell|w|m)\\s+(\\S+)\\s+(.+)$", Pattern.CASE_INSENSITIVE);
    // /r, /reply + スペース + メッセージ本文（相手なし）
    private static final Pattern REPLY_CMD_PATTERN =
            Pattern.compile("^/(r|reply)\\s+(.+)$", Pattern.CASE_INSENSITIVE);

    /** 変換処理中のプレイヤー（無限ループ防止） */
    private final Set<UUID> processing = Collections.synchronizedSet(new HashSet<>());

    private HttpClient httpClient;

    /** Discord 認証済み（user グループ）のプレイヤーだけが持つ建築許可ノード */
    private static final String BUILD_PERMISSION = "tus.build";

    @Override
    public void onEnable() {
        httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build();
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

    /**
     * PlayerCommandPreprocessEvent でプライベートメッセージコマンドを横取りし、
     * メッセージ部分をローマ字→日本語変換して再ディスパッチする。
     *
     * 処理フロー:
     *  1. コマンドが /msg /tell /w /m /r /reply か確認
     *  2. 対象外・日本語含む・変換中 → スルー
     *  3. イベントをキャンセルし、非同期スレッドで Google API 変換
     *  4. メインスレッドに戻り変換済みコマンドを performCommand で再実行
     */
    @EventHandler(priority = EventPriority.HIGHEST, ignoreCancelled = true)
    public void onPrivateMessage(PlayerCommandPreprocessEvent event) {
        Player player = event.getPlayer();
        UUID uuid = player.getUniqueId();

        // 変換中の再帰呼び出しを防ぐ
        if (processing.contains(uuid)) return;

        String raw = event.getMessage();

        java.util.regex.Matcher msgMatcher   = MSG_CMD_PATTERN.matcher(raw);
        java.util.regex.Matcher replyMatcher = REPLY_CMD_PATTERN.matcher(raw);

        final String baseCmd;   // 変換前コマンド（/msg player ）or（/r ）
        final String msgText;   // 変換対象のメッセージ部分

        if (msgMatcher.matches()) {
            // /msg <player> <message>
            baseCmd = "/" + msgMatcher.group(1) + " " + msgMatcher.group(2) + " ";
            msgText = msgMatcher.group(3);
        } else if (replyMatcher.matches()) {
            // /r <message>
            baseCmd = "/" + replyMatcher.group(1) + " ";
            msgText = replyMatcher.group(2);
        } else {
            return;
        }

        // ASCII ローマ字でなければ変換不要
        if (!ROMAJI_PATTERN.matcher(msgText).matches()) return;

        // メインスレッドをブロックしないよう非同期で変換
        event.setCancelled(true);
        processing.add(uuid);

        Bukkit.getScheduler().runTaskAsynchronously(this, () -> {
            String japanese = convertToJapanese(msgText);
            String finalMsg = (japanese != null && !japanese.isEmpty() && !japanese.equals(msgText))
                    ? msgText + " (" + japanese + ")"
                    : msgText;

            // コマンド再実行はメインスレッドで
            Bukkit.getScheduler().runTask(this, () -> {
                try {
                    player.performCommand((baseCmd + finalMsg).replaceFirst("^/", ""));
                } finally {
                    processing.remove(uuid);
                }
            });
        });
    }

    /**
     * MONITOR 優先度で AsyncChatEvent を処理。
     * loadbefore: [DiscordSRV] により DiscordSRV のリスナーより先に呼ばれる。
     *
     * 処理:
     * 1. メッセージが ASCII ローマ字か確認
     * 2. Google Input Tools API で日本語に変換
     * 3. event.renderer() を上書き → ゲーム内も当プラグインの変換結果を表示
     * 4. event.message() を更新 → Discord にも同じ変換結果が届く
     */
    @EventHandler(priority = EventPriority.MONITOR)
    public void onChat(AsyncChatEvent event) {
        String romaji = PlainTextComponentSerializer.plainText()
                .serialize(event.message());

        // 空メッセージ・日本語含む場合はスキップ
        if (romaji.isBlank() || !ROMAJI_PATTERN.matcher(romaji).matches()) {
            return;
        }

        String japanese = convertToJapanese(romaji);
        if (japanese == null || japanese.isEmpty() || japanese.equals(romaji)) {
            return;
        }

        // ゲーム内表示用に元のローマ字 Component を保存
        Component romajiComponent = event.message();

        // ゲーム内: JapanizeChat の renderer を上書きして当プラグインの変換結果を使用
        // 「ローマ字 (日本語)」形式で表示（日本語部分はグレー）
        Component japaneseAnnotation = Component.text(" (" + japanese + ")")
                .color(NamedTextColor.GRAY);
        event.renderer((source, displayName, message, viewer) ->
                ChatRenderer.defaultRenderer()
                        .render(source, displayName, romajiComponent, viewer)
                        .append(japaneseAnnotation)
        );

        // Discord 用: event.message() に「ローマ字 (日本語)」を設定
        event.message(Component.text(romaji + " (" + japanese + ")"));
    }

    /**
     * Google Input Tools API でローマ字を日本語に変換する。
     * 同期呼び出し（AsyncChatEvent のハンドラは非同期スレッド上で動くため Main Thread をブロックしない）。
     *
     * レスポンス例:
     *   ["SUCCESS",[["konnichiha",[["こんにちは","こんにちは","こんにちわ"],...],null,null,{...}]]]
     *
     * @param romaji 変換元のローマ字文字列
     * @return 変換後の日本語文字列。失敗時は null
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
            // タイムアウトや接続エラーは無視してローマ字のままにする
            getLogger().fine("Google API 変換失敗 (無視): " + e.getMessage());
            return null;
        }
    }

    /**
     * Google Input Tools API のレスポンスを解析し、第一候補の日本語文字列を返す。
     *
     * 実際のレスポンス例:
     *   ["SUCCESS",[["konnichiha",["こんにちは"],[],{"candidate_type":[0],"matched_length":[5]}]]]
     *
     * 構造:
     *   1番目の文字列 = "SUCCESS"
     *   2番目の文字列 = 入力テキスト "konnichiha"
     *   3番目の文字列 = 第一候補 "こんにちは" ← これを返す
     *
     * ※ 括弧カウント方式だと ["candidate"],[],{"candidate_type":[0]...} の
     *    空配列 [] が5番目の [ になり "candidate_type" が取れてしまうバグがあった
     */
    private String parseGoogleResponse(String json) {
        if (json == null || !json.contains("SUCCESS")) return null;
        try {
            int pos = 0;

            // 1番目の文字列 "SUCCESS" をスキップ
            int open1 = json.indexOf('"', pos);
            if (open1 < 0) return null;
            int close1 = json.indexOf('"', open1 + 1);
            if (close1 < 0) return null;
            pos = close1 + 1;

            // 2番目の文字列（入力テキスト）をスキップ
            int open2 = json.indexOf('"', pos);
            if (open2 < 0) return null;
            int close2 = json.indexOf('"', open2 + 1);
            if (close2 < 0) return null;
            pos = close2 + 1;

            // 3番目の文字列 = 第一候補
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
