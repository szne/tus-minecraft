package me.tus.japanizechat;

import io.papermc.paper.chat.ChatRenderer;
import io.papermc.paper.event.player.AsyncChatEvent;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.plugin.java.JavaPlugin;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

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
    private static final java.util.regex.Pattern ROMAJI_PATTERN =
            java.util.regex.Pattern.compile("^[\\x20-\\x7E]+$");

    private HttpClient httpClient;

    @Override
    public void onEnable() {
        httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(3))
                .build();
        getServer().getPluginManager().registerEvents(this, this);
        getLogger().info("JapanizeDiscordBridge 有効化 — ゲーム内・Discord 両方に日本語変換を適用します");
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
