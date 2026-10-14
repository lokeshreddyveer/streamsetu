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
class StreamResolver(private val sources: SourceRepository, private val credentials: CredentialStore, context: Context) : app.streamsetu.core.playback.StreamUrlResolver {
    private val prefs = context.applicationContext.getSharedPreferences("account-formats", Context.MODE_PRIVATE)

    override suspend fun resolve(sourceId: String, streamRef: String): String? {
        if (streamRef.startsWith("http://") || streamRef.startsWith("https://") || streamRef.startsWith("rtmp") || streamRef.startsWith("rtsp")) return streamRef
        val s = sources.get(sourceId) ?: return null
        if (s.type != SourceType.XTREAM) return null
        val pass = credentials.load(SourceRepository.credentialRef(s.id)) ?: return null
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

    /** The number of simultaneous streams the account allows, as the provider says it. 0 when unknown. */
    fun rememberMaxConnections(sourceId: String, max: Int) { if (max > 0) prefs.edit().putInt("max.$sourceId", max).apply() }

    fun remember(sourceId: String, formats: List<String>) { if (formats.isNotEmpty()) prefs.edit().putString(sourceId, formats.joinToString(",")).apply() }

    companion object {
        /** HLS when the account allows it, otherwise MPEG-TS; an account that does not say gets what the playlist stored. */
        fun pickLiveFormat(allowed: List<String>, stored: String): String = when {
            allowed.isEmpty() -> stored.ifBlank { "m3u8" }
            "m3u8" in allowed -> "m3u8"
            "ts" in allowed -> "ts"
            else -> allowed.first()
        }
    }
}
