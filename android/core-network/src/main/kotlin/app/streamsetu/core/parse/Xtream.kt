package app.streamsetu.core.parse

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject

/** Xtream-style server: the addresses it exposes and how to read its answers. Providers differ a lot, so every read is lenient. */
object Xtream {
    val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun normalizeHost(address: String): String {
        var a = address.trim().trimEnd('/')
        if ("://" !in a) a = "http://$a"
        return a.removeSuffix("/player_api.php").removeSuffix("/get.php")
    }

    fun api(host: String, user: String, pass: String, action: String? = null, extra: String = ""): String {
        val q = "username=${enc(user)}&password=${enc(pass)}" + (action?.let { "&action=$it" } ?: "") + extra
        return "${normalizeHost(host)}/player_api.php?$q"
    }

    /** A playable address. `ref` is "live:ID:ext", "movie:ID:ext" or "series:ID:ext". */
    fun streamUrl(host: String, user: String, pass: String, ref: String): String? {
        val p = ref.split(':')
        if (p.size < 3) return null
        val (type, id, ext) = Triple(p[0], p[1], p[2])
        val base = normalizeHost(host)
        return "$base/$type/${enc(user)}/${enc(pass)}/$id.${ext.ifBlank { if (type == "live") "m3u8" else "mp4" }}"
    }

    /** The archive address of a programme: `/timeshift/user/pass/minutes/yyyy-MM-dd:HH-mm/streamId.ts`. [zone] is the time zone the provider reads the start time in. */
    fun timeshiftUrl(host: String, user: String, pass: String, streamId: String, startMs: Long, minutes: Long, zone: java.util.TimeZone): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd:HH-mm", java.util.Locale.US).apply { timeZone = zone }
        return "${normalizeHost(host)}/timeshift/${enc(user)}/${enc(pass)}/$minutes/${f.format(java.util.Date(startMs))}/$streamId.ts"
    }

    fun parseArray(text: String): List<JsonObject> {
        val el = runCatching { json.parseToJsonElement(text) }.getOrNull() ?: return emptyList()
        return when (el) {
            is JsonArray -> el.mapNotNull { it as? JsonObject }
            is JsonObject -> el.values.mapNotNull { it as? JsonObject }       // some servers answer with an object keyed by id
            else -> emptyList()
        }
    }

    fun parseObject(text: String): JsonObject? = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()

    private fun enc(s: String) = java.net.URLEncoder.encode(s, "UTF-8")
}

fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() && it != "null" }
fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.let { it.intOrNull ?: it.contentOrNull?.toDoubleOrNull()?.toInt() }
fun JsonElement?.obj(): JsonObject? = this as? JsonObject
