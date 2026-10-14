package app.streamsetu.core.net

import android.content.Context
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.int
import app.streamsetu.core.parse.str
import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Turns the reference stored with a channel, movie or episode into the address the player opens.
 * For Xtream live channels it also picks the format the ACCOUNT allows: many providers only serve MPEG-TS ("ts") and refuse HLS ("m3u8"),
 * which is what `allowed_output_formats` in the login answer says. That answer is remembered per playlist.
 */
class StreamResolver(private val sources: SourceRepository, private val credentials: CredentialStore, private val context: Context) : app.streamsetu.core.playback.StreamUrlResolver {
    private val prefs = context.applicationContext.getSharedPreferences("account-formats", Context.MODE_PRIVATE)

    override suspend fun userAgent(sourceId: String): String? = sources.get(sourceId)?.userAgent?.takeIf { it.isNotBlank() }

    private val stalker = StalkerClient()
    private val sessions = MediaSessions(credentials)
    private val plex = PlexClient()
    private val dav = WebDavClient()
    private val headerPrefs = context.applicationContext.getSharedPreferences("source-headers", Context.MODE_PRIVATE)

    /** Extra request headers the person set for a connection, one "Name: value" per line. */
    fun customHeadersText(sourceId: String): String = headerPrefs.getString("h.$sourceId", "").orEmpty()
    fun setCustomHeaders(sourceId: String, text: String) { headerPrefs.edit().apply { if (text.isBlank()) remove("h.$sourceId") else putString("h.$sourceId", text.trim()) }.apply() }

    override suspend fun headers(sourceId: String): Map<String, String> {
        val out = LinkedHashMap(parseHeaders(customHeadersText(sourceId)))
        val s = sources.get(sourceId) ?: return out
        val user = s.username?.takeIf { it.isNotBlank() }
        if (user != null && (s.type == SourceType.TVHEADEND || s.type == SourceType.ENIGMA2 || s.type == SourceType.WEBDAV) && out.keys.none { it.equals("Authorization", true) })
            out["Authorization"] = Http.basic(user, credentials.load(SourceRepository.credentialRef(s.id)).orEmpty())
        return out
    }

    override suspend fun resolve(sourceId: String, streamRef: String): String? {
        if (streamRef.startsWith("stalker:")) {
            val src = sources.get(sourceId) ?: return null
            return withContext(Dispatchers.IO) { runCatching { stalker.link(src, streamRef.removePrefix("stalker:")) }.getOrNull() }
        }
        if (streamRef.startsWith("content://") || streamRef.startsWith("file://")) return streamRef
        if (streamRef.startsWith("http://") || streamRef.startsWith("https://") || streamRef.startsWith("rtmp") || streamRef.startsWith("rtsp")) return streamRef
        val s = sources.get(sourceId) ?: return null
        when {
            streamRef.startsWith("jf:") -> return withContext(Dispatchers.IO) { runCatching { sessions.with(s) { sessions.client.streamUrl(s, it, streamRef) } }.getOrNull() }
            streamRef.startsWith("plex:") -> return plex.streamUrl(s, credentials.load(SourceRepository.credentialRef(s.id)).orEmpty(), streamRef)
            streamRef.startsWith("dav:") -> return dav.streamUrl(s, streamRef)
            streamRef.startsWith("e2:") -> return Enigma2.streamUrl(s.address, streamRef)
        }
        if (s.type != SourceType.XTREAM) return null
        val pass = credentials.load(SourceRepository.credentialRef(s.id)) ?: return null
        if (streamRef.startsWith("timeshift:")) {
            val p = streamRef.split(':')
            val zone = if (context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString("catchupZone", "UTC") == "DEVICE") java.util.TimeZone.getDefault() else java.util.TimeZone.getTimeZone("UTC")
            return Xtream.timeshiftUrl(s.address, s.username.orEmpty(), pass, p.getOrNull(1).orEmpty(), p.getOrNull(2)?.toLongOrNull() ?: return null, p.getOrNull(3)?.toLongOrNull() ?: 60, zone)
        }
        var ref = streamRef
        if (ref.startsWith("live:")) {
            val parts = ref.split(':')
            val allowed = allowedFormats(sourceId, s.address, s.username.orEmpty(), pass)
            val ext = pickLiveFormat(allowed, parts.getOrNull(2).orEmpty())
            ref = "live:${parts.getOrNull(1)}:$ext"
        }
        return Xtream.streamUrl(s.address, s.username.orEmpty(), pass, ref)
    }

    /** Remembers what the login answer said (and asks once if it has not been asked yet). */
    private suspend fun allowedFormats(sourceId: String, host: String, user: String, pass: String): List<String> {
        prefs.getString(sourceId, null)?.let { return it.split(',').filter { f -> f.isNotBlank() } }
        val list = withContext(Dispatchers.IO) {
            runCatching {
                val auth = Xtream.parseObject(Http.text(Xtream.api(host, user, pass)))
                val info = auth?.get("user_info") as? JsonObject
                (info?.get("allowed_output_formats") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
            }.getOrDefault(emptyList())
        }
        if (list.isNotEmpty()) prefs.edit().putString(sourceId, list.joinToString(",")).apply()
        return list
    }

    /** True when the provider is known to allow only one stream at a time. */
    fun allowsOnlyOneStream(sourceId: String): Boolean = prefs.getInt("max.$sourceId", 0) == 1

    /** The number of simultaneous streams the account allows, as the provider says it. 0 when unknown. */
    fun rememberMaxConnections(sourceId: String, max: Int) { if (max > 0) prefs.edit().putInt("max.$sourceId", max).apply() }

    fun remember(sourceId: String, formats: List<String>) { if (formats.isNotEmpty()) prefs.edit().putString(sourceId, formats.joinToString(",")).apply() }

    companion object {
        /** "Name: value" lines to a map; blank and malformed lines are ignored. */
        fun parseHeaders(text: String): Map<String, String> = text.lines().mapNotNull { l -> val i = l.indexOf(':'); if (i <= 0) null else l.substring(0, i).trim() to l.substring(i + 1).trim() }
            .filter { (k, v) -> k.isNotEmpty() && v.isNotEmpty() && k.none { it.isWhitespace() } }.toMap()

        /** HLS when the account allows it, otherwise MPEG-TS; an account that does not say gets what the playlist stored. */
        fun pickLiveFormat(allowed: List<String>, stored: String): String = when {
            allowed.isEmpty() -> stored.ifBlank { "m3u8" }
            "m3u8" in allowed -> "m3u8"
            "ts" in allowed -> "ts"
            else -> allowed.first()
        }
    }
}
