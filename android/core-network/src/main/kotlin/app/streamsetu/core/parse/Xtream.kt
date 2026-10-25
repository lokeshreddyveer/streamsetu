package app.streamsetu.core.parse

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeToSequence
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

    /**
     * Reads a list from a provider one item at a time, without holding the whole answer in memory: a library of tens of thousands of films is tens of megabytes of text, and a TV
     * stick with a small heap used to run out of memory part way, which ended as a shorter library without a word. A list that starts like a list but breaks off part way is an
     * error (so the library already stored is kept, not replaced by half of one); an answer that is empty or not a list at all is an empty list, as before.
     */
    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun forEachObject(input: java.io.InputStream, onItem: (JsonObject) -> Unit) {
        val stream = java.io.BufferedInputStream(input, 64 * 1024)
        stream.mark(3)
        if (!(stream.read() == 0xEF && stream.read() == 0xBB && stream.read() == 0xBF)) stream.reset()      // a byte order mark in front of the text is skipped
        stream.mark(8192)
        var first = -1
        for (i in 0 until 8192) { val b = stream.read(); if (b < 0) break; if (!b.toChar().isWhitespace()) { first = b; break } }
        stream.reset()
        when (first.toChar()) {
            '[' -> json.decodeToSequence(stream, kotlinx.serialization.json.JsonElement.serializer(), kotlinx.serialization.json.DecodeSequenceMode.ARRAY_WRAPPED).forEach { (it as? JsonObject)?.let(onItem) }
            '{' -> parseArray(stream.readBytes().decodeToString()).forEach(onItem)       // some servers answer with an object keyed by id
            else -> {}
        }
    }

    /** One episode of a series, as the provider names it. */
    data class EpisodeRow(val id: String, val season: Int, val number: Int, val title: String, val plot: String?, val image: String?, val durationSecs: Int?, val extension: String)

    /**
     * The episodes in a `get_series_info` answer. Providers lay them out in more than one way: an object keyed by season ("1": [...], "10": [...]), an array with one list per season
     * (seasons counted from 1, as the Apple apps do), a season whose episodes are an object keyed by position, or a flat list of episodes. All of them are read. An episode's own
     * `season` field wins over the key it sits under; one with no number gets its position in its season.
     */
    fun episodes(answer: JsonObject): List<EpisodeRow> {
        val groups: List<Pair<String, JsonElement>> = when (val root = answer["episodes"]) {
            is JsonObject -> root.entries.map { it.key to it.value }
            is kotlinx.serialization.json.JsonArray -> root.mapIndexed { i, el -> (i + 1).toString() to el }
            else -> return emptyList()
        }
        val out = ArrayList<EpisodeRow>()
        for ((key, group) in groups) {
            val items: List<JsonElement> = when (group) {
                is kotlinx.serialization.json.JsonArray -> group
                is JsonObject -> if (group.containsKey("id")) listOf(group) else group.values.toList()
                else -> emptyList()
            }
            items.forEachIndexed { idx, el ->
                val e = el as? JsonObject ?: return@forEachIndexed
                val id = e.str("id") ?: return@forEachIndexed
                val info = e["info"] as? JsonObject
                val number = e.int("episode_num") ?: (idx + 1)
                out += EpisodeRow(id, e.int("season") ?: key.toIntOrNull() ?: 1, number, e.str("title") ?: "Episode $number", info?.str("plot"), info?.str("movie_image"), info?.int("duration_secs"), e.str("container_extension") ?: "mp4")
            }
        }
        return out
    }

    fun parseObject(text: String): JsonObject? = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()

    private fun enc(s: String) = java.net.URLEncoder.encode(s, "UTF-8")
}

fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() && it != "null" }
fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.let { it.intOrNull ?: it.contentOrNull?.toDoubleOrNull()?.toInt() }
fun JsonElement?.obj(): JsonObject? = this as? JsonObject
