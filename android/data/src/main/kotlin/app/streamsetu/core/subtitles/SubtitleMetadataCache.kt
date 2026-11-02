package app.streamsetu.core.subtitles

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * What a provider answered for one question (title, year, season, episode, language), kept as small JSON and apart from the subtitle files themselves. Asking again within [ttlMs]
 * is answered from here, so the "Find subtitles" panel opens at once and the provider is not asked twice. Old entries are removed beyond [MAX_FILES]. The answers hold titles and
 * file names only: no login, no address of the person's provider and no download link.
 */
class SubtitleMetadataCache(private val dir: File, private val ttlMs: Long = 6L * 3600_000, private val now: () -> Long = System::currentTimeMillis) {
    init { dir.mkdirs() }

    fun key(want: SubtitleWanted) = SubtitleFiles.sha256("${want.title.lowercase().trim()}|${want.year}|${want.season}|${want.episode}|${want.language.lowercase()}".toByteArray())

    fun get(want: SubtitleWanted): List<SubtitleCandidate>? {
        val f = File(dir, key(want) + ".json"); if (!f.exists()) return null
        return runCatching {
            val o = JSONObject(f.readText())
            if (now() - o.getLong("savedAt") > ttlMs) { f.delete(); return null }
            val a = o.getJSONArray("c"); (0 until a.length()).map { decode(a.getJSONObject(it)) }
        }.getOrNull()
    }

    fun put(want: SubtitleWanted, found: List<SubtitleCandidate>) {
        val o = JSONObject().put("savedAt", now()).put("c", JSONArray().also { a -> found.take(60).forEach { a.put(encode(it)) } })
        runCatching { File(dir, key(want) + ".json").writeText(o.toString()) }
        prune()
    }

    fun clear() { dir.listFiles()?.forEach { it.delete() } }

    private fun prune() {
        val files = dir.listFiles { f -> f.extension == "json" }?.sortedByDescending { it.lastModified() } ?: return
        files.drop(MAX_FILES).forEach { it.delete() }
    }

    private fun encode(c: SubtitleCandidate) = JSONObject().put("id", c.fileId).put("name", c.fileName).put("rel", c.release).put("lang", c.language).put("dl", c.downloads).put("rt", c.rating)
        .put("hi", c.hearingImpaired).put("hash", c.hashMatch).put("tr", c.trusted).put("ai", c.aiTranslated).put("mt", c.machineTranslated).put("prov", c.provider).also { o ->
            c.title?.let { o.put("t", it) }; c.year?.let { o.put("y", it) }; c.season?.let { o.put("s", it) }; c.episode?.let { o.put("e", it) }; c.runtimeMinutes?.let { o.put("m", it) } }

    private fun decode(o: JSONObject) = SubtitleCandidate(
        o.getLong("id"), o.optString("name"), o.optString("rel"), o.optString("lang"), o.optInt("dl"), o.optDouble("rt", 0.0), o.optBoolean("hi"), o.optBoolean("hash"), o.optBoolean("tr"),
        o.optBoolean("ai"), o.optBoolean("mt"), o.optString("t").takeIf { o.has("t") }, o.optInt("y").takeIf { o.has("y") }, o.optInt("s").takeIf { o.has("s") }, o.optInt("e").takeIf { o.has("e") },
        o.optInt("m").takeIf { o.has("m") }, o.optString("prov", "OpenSubtitles"),
    )

    companion object { const val MAX_FILES = 60 }
}
