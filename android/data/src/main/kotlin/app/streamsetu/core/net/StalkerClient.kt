package app.streamsetu.core.net

import app.streamsetu.core.model.Source
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.int
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import okhttp3.Request
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

data class StalkerChannel(val id: String, val name: String, val number: Int?, val logo: String?, val cmd: String, val genreId: String?, val epgId: String?)
data class StalkerGenre(val id: String, val title: String)

/**
 * A client for Stalker / Ministra portals (the "MAC address" kind of IPTV login). The portal's address is what the person types (usually ending in /c/); the MAC address is
 * kept in the connection's user-name field. Only live TV is read for now; video-on-demand portals are not supported yet.
 * Each call identifies itself like a set-top box, with the MAC in a cookie and the session token as a bearer header.
 */
class StalkerClient {
    private val tokens = ConcurrentHashMap<String, String>()

    /** `http://host/c/` or `http://host/stalker_portal/c` to `http://host/stalker_portal/server/load.php`. */
    fun loadUrl(portal: String): String {
        var p = portal.trim().trimEnd('/')
        if (!p.startsWith("http", ignoreCase = true)) p = "http://$p"
        p = p.removeSuffix("/c")
        return if (p.endsWith("load.php")) p else "$p/server/load.php"
    }

    private fun get(source: Source, query: String, token: String?): String {
        val base = loadUrl(source.address)
        val mac = source.username.orEmpty().trim().uppercase()
        val ua = source.userAgent?.takeIf { it.isNotBlank() } ?: "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG250 stbapp ver: 2 rev: 250 Safari/533.3"
        val req = Request.Builder().url("$base?$query&JsHttpRequest=1-xml")
            .header("User-Agent", ua).header("X-User-Agent", "Model: MAG250; Link: WiFi")
            .header("Cookie", "mac=$mac; stb_lang=en; timezone=UTC")
            .apply { if (!token.isNullOrBlank()) header("Authorization", "Bearer $token") }.build()
        Http.client.newCall(req).execute().use { r ->
            if (!r.isSuccessful) error("The portal answered ${r.code}")
            return r.body?.string().orEmpty()
        }
    }

    private fun js(text: String): JsonObject? = Xtream.parseObject(text)?.get("js") as? JsonObject

    /** Signs in and remembers the session token for this connection. */
    fun handshake(source: Source): String {
        val o = js(get(source, "type=stb&action=handshake&token=", null)) ?: error("The portal did not answer the sign-in request.")
        val token = o.str("token") ?: error("The portal did not give a session. Check the portal address and the MAC address.")
        tokens[source.id] = token
        // Some portals need the profile read once before they serve channels.
        runCatching { get(source, "type=stb&action=get_profile&hd=1&ver=ImageDescription:%200.2.18-r14-pub-250;&num_banks=2&sn=&stb_type=MAG250&client_type=STB&image_version=218&video_out=hdmi&auth_second_step=0&hw_version=1.7-BD-00&not_valid_token=0&metrics=%7B%7D&hw_version_2=&api_signature=262&prehash=", token) }
        return token
    }

    private fun session(source: Source): String = tokens[source.id] ?: handshake(source)

    /** Runs a call; when the session has gone stale it signs in once more and tries again. */
    private fun <T> withSession(source: Source, call: (String) -> T): T = try { call(session(source)) } catch (e: Exception) { tokens.remove(source.id); call(handshake(source)) }

    fun genres(source: Source): List<StalkerGenre> = withSession(source) { t ->
        val arr = Xtream.parseObject(get(source, "type=itv&action=get_genres", t))?.get("js") as? JsonArray ?: return@withSession emptyList()
        arr.mapNotNull { (it as? JsonObject)?.let { g -> val id = g.str("id") ?: return@let null; StalkerGenre(id, g.str("title") ?: g.str("name") ?: id) } }
    }

    fun channels(source: Source): List<StalkerChannel> = withSession(source) { t ->
        val data = js(get(source, "type=itv&action=get_all_channels", t))?.get("data") as? JsonArray ?: return@withSession emptyList()
        data.mapNotNull { (it as? JsonObject)?.let { o ->
            val id = o.str("id") ?: return@let null; val cmd = o.str("cmd") ?: return@let null
            StalkerChannel(id, o.str("name") ?: "Channel $id", o.int("number"), o.str("logo")?.takeIf { l -> l.isNotBlank() }, cmd, o.str("tv_genre_id"), o.str("xmltv_id")?.takeIf { x -> x.isNotBlank() })
        } }
    }

    /** A stream address is made on demand: the portal hands out a short-lived link for the channel's command. */
    fun link(source: Source, cmd: String): String? = withSession(source) { t ->
        val made = js(get(source, "type=itv&action=create_link&cmd=${URLEncoder.encode(cmd, "UTF-8")}&series=&forced_storage=&disable_ip_check=0", t))?.str("cmd")
        stripPrefix(made ?: cmd)
    }

    companion object {
        /** "ffmpeg http://host/stream" and "auto http://..." carry a player hint before the address. */
        fun stripPrefix(cmd: String): String? = cmd.trim().let { c -> c.substringAfter(' ', c).trim() }.takeIf { it.startsWith("http", ignoreCase = true) || it.startsWith("rtmp") || it.startsWith("rtsp") }
    }
}
