package app.streamsetu.core.data.repo

import app.streamsetu.core.data.smartmix.*
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.int
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.*
import java.io.File
import java.net.URLEncoder
import java.security.MessageDigest

/**
 * What TMDB is asked for besides artwork, always with the person's OWN key (there is no bundled key) and never anything about the person: only a title name and year, or the public weekly
 * trending lists. Everything fetched is kept in files of its own, shown for at most [TmdbFiles.SOFT_DAYS] days without a refresh and deleted at [TmdbFiles.MAX_DAYS] days (TMDB's six month limit).
 * "This product uses the TMDB API but is not endorsed or certified by TMDB."
 */
object TmdbFiles {
    const val SOFT_DAYS = 30
    const val MAX_DAYS = 180
    const val DAY_MS = 86_400_000L
    private const val MAX_FILES = 300
    /** The record of which titles TMDB filled in and when: it outlives the lists (it is what lets the 180-day limit and a lock take that data back) and is removed by [TmdbService.purge] only. */
    const val KEEP = "filled.log"

    /** Deletes saved TMDB data older than the limit (and the oldest files beyond a count). Returns how many files went. */
    fun purge(dir: File, now: Long = System.currentTimeMillis(), maxDays: Int = MAX_DAYS): Int {
        val files = dir.listFiles()?.filter { it.isFile && it.name != KEEP }?.sortedBy { it.lastModified() } ?: return 0
        var n = 0
        for ((i, f) in files.withIndex()) if (now - f.lastModified() > maxDays * DAY_MS || i < files.size - MAX_FILES) { if (f.delete()) n++ }
        return n
    }
    /** Everything TMDB gave this device is removed (the switch turned off, the key removed, or "Clear"). */
    fun clear(dir: File) { dir.listFiles()?.filter { it.name != KEEP }?.forEach { it.delete() } }
}

class TmdbCast(private val key: () -> String?, private val dir: File, private val fetch: (String) -> String = { Http.text(it) }, private val now: () -> Long = System::currentTimeMillis) {
    data class Member(val id: Long, val name: String, val role: String?, val photo: String?)

    companion object {
        const val MAX_MEMBERS = 14
        fun parseSearch(json: String): Long? = ((Xtream.parseObject(json)?.get("results") as? JsonArray)?.firstOrNull() as? JsonObject)?.get("id")?.jsonPrimitive?.longOrNull
        fun parseCredits(json: String): List<Member> {
            val cast = (Xtream.parseObject(json)?.get("cast") as? JsonArray) ?: return emptyList()
            return cast.mapNotNull { e -> (e as? JsonObject)?.let { o ->
                val name = o.str("name") ?: return@let null
                Member(o["id"]?.jsonPrimitive?.longOrNull ?: return@let null, name, o.str("character"), o.str("profile_path")?.let { "https://image.tmdb.org/t/p/w185$it" })
            } }.take(MAX_MEMBERS)
        }
    }

    /** True when the person has given their own key: the cast row is drawn only then. */
    val enabled get() = !key().isNullOrBlank()

    /** The cast of a title, from the saved copy when it is under 30 days old. Empty with no key, no match, or no network. Blocking: call off the main thread. */
    fun cast(title: String, year: Int?, series: Boolean): List<Member> {
        val k = key()?.takeIf { it.isNotBlank() } ?: return emptyList()
        val q = TmdbService.query(title, year)
        if (q.title.length < 2) return emptyList()
        val file = File(dir, "cast-" + sha("${if (series) "tv" else "movie"}|${q.title.lowercase()}|${q.year}") + ".json")
        if (file.isFile && now() - file.lastModified() < TmdbFiles.SOFT_DAYS * TmdbFiles.DAY_MS) runCatching { return parseCredits(file.readText()) }
        val kind = if (series) "tv" else "movie"
        return runCatching {
            val search = fetch("https://api.themoviedb.org/3/search/$kind?api_key=${URLEncoder.encode(k, "UTF-8")}&query=${URLEncoder.encode(q.title, "UTF-8")}" + (q.year?.let { if (series) "&first_air_date_year=$it" else "&year=$it" } ?: ""))
            val id = parseSearch(search) ?: return@runCatching emptyList()
            val credits = fetch("https://api.themoviedb.org/3/$kind/$id/credits?api_key=${URLEncoder.encode(k, "UTF-8")}")
            dir.mkdirs(); file.writeText(credits)
            parseCredits(credits)
        }.getOrDefault(emptyList())
    }

    private fun sha(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).take(10).joinToString("") { "%02x".format(it) }
}

/** The public weekly trending lists (movies and tv), one request each, with the person's own key. Nothing about the person is part of the request. */
class TmdbTrendingFetcher(private val fetch: (String) -> String = { Http.text(it) }) : TrendingFetcher {
    companion object {
        fun parse(json: String, type: String): List<TrendingEntry> {
            val results = (Xtream.parseObject(json)?.get("results") as? JsonArray) ?: return emptyList()
            return results.mapIndexedNotNull { i, e -> (e as? JsonObject)?.let { o ->
                val title = (if (type == "movie") o.str("title") else o.str("name")) ?: return@let null
                val orig = if (type == "movie") o.str("original_title") else o.str("original_name")
                val year = (if (type == "movie") o.str("release_date") else o.str("first_air_date"))?.take(4)?.toIntOrNull()
                TrendingEntry(i + 1, type, title, orig?.takeIf { it != title }, year)
            } }
        }
    }
    override fun fetchWeekly(apiKey: String): TrendingSnapshot? = runCatching {
        val k = URLEncoder.encode(apiKey, "UTF-8")
        val movies = parse(fetch("https://api.themoviedb.org/3/trending/movie/week?api_key=$k"), "movie")
        val tv = parse(fetch("https://api.themoviedb.org/3/trending/tv/week?api_key=$k"), "tv")
        if (movies.isEmpty() && tv.isEmpty()) null else TrendingSnapshot(System.currentTimeMillis(), movies + tv)
    }.getOrNull()
}

/** The weekly list kept in a file of its own; its age is the file's own time of saving. */
class FileTrendingCache(private val file: File) : TrendingCacheStore {
    override fun load(): TrendingSnapshot? = runCatching {
        if (!file.isFile) return null
        val o = Json.parseToJsonElement(file.readText()).jsonObject
        TrendingSnapshot(o["at"]!!.jsonPrimitive.long, (o["e"] as JsonArray).map { e -> e.jsonObject.let { TrendingEntry(it["r"]!!.jsonPrimitive.int, it["t"]!!.jsonPrimitive.content, it["n"]!!.jsonPrimitive.content, it["o"]?.jsonPrimitive?.contentOrNull, it["y"]?.jsonPrimitive?.intOrNull) } })
    }.getOrNull()
    override fun save(snapshot: TrendingSnapshot) {
        file.parentFile?.mkdirs()
        file.writeText(buildJsonObject {
            put("at", snapshot.fetchedAtMillis)
            put("e", buildJsonArray { snapshot.entries.forEach { e -> add(buildJsonObject { put("r", e.rank); put("t", e.type); put("n", e.title); e.original?.let { put("o", it) }; e.year?.let { put("y", it) } }) } })
        }.toString())
    }
    override fun clear() { file.delete() }
}
