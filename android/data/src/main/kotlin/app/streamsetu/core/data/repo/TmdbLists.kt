package app.streamsetu.core.data.repo

import app.streamsetu.core.data.smartmix.GenreShelves
import app.streamsetu.core.data.smartmix.RankedLists
import app.streamsetu.core.data.smartmix.GenreTable
import app.streamsetu.core.data.smartmix.TrendingEntry
import kotlinx.serialization.json.*
import java.io.File

/**
 * TMDB's public ranked lists for the shelves: `top` (top rated), `week:<genre>` and `top:<genre>` (discover by genre, most popular or best rated with enough votes). A request carries
 * only the list name's own parameters (sort order, genre ids, language of the original): nothing about the person, the library, the history or the device. One file per list in the TMDB folder, used
 * for 30 days, deleted after 180, refetched when stale (week* 24 hours, the others 168); a failed fetch keeps the old file. The credential is [TmdbAuth]'s.
 */
class TmdbLists(private val auth: TmdbAuth, private val dir: File, private val enabled: () -> Boolean = { true }, private val fetch: TmdbCall = tmdbHttp, private val now: () -> Long = System::currentTimeMillis) : RankedLists {
    companion object {
        const val PREFIX = "list-"
        private fun safe(name: String) = name.replace(':', '_').filter { it.isLetterOrDigit() || it == '_' || it == '-' }

        /** Movie and tv alternate (movie 1, tv 1, movie 2, ...) and are numbered again. */
        fun interleave(movies: List<TrendingEntry>, tv: List<TrendingEntry>): List<TrendingEntry> {
            val out = ArrayList<TrendingEntry>(); var i = 0
            while (i < movies.size || i < tv.size) { movies.getOrNull(i)?.let { out += it }; tv.getOrNull(i)?.let { out += it }; i++ }
            return out.mapIndexed { n, e -> e.copy(rank = n + 1) }
        }
    }

    private fun file(name: String) = File(dir, "$PREFIX${safe(name)}.json")
    private fun age(f: File) = now() - f.lastModified()

    private fun load(f: File): List<TrendingEntry>? = runCatching {
        val o = Json.parseToJsonElement(f.readText()).jsonObject
        (o["e"] as JsonArray).map { e -> e.jsonObject.let { TrendingEntry(it["r"]!!.jsonPrimitive.int, it["t"]!!.jsonPrimitive.content, it["n"]!!.jsonPrimitive.content, it["o"]?.jsonPrimitive?.contentOrNull, it["y"]?.jsonPrimitive?.intOrNull) } }
    }.getOrNull()

    /** The saved list while at most 30 days old; one past 180 days is deleted. Null without a credential or with the switch off (nothing is used then). */
    override fun entries(name: String, nowMillis: Long): List<TrendingEntry>? {
        if (!enabled() || !auth.available) return null
        val f = file(name).takeIf { it.isFile } ?: return null
        val days = (now() - f.lastModified()) / TmdbFiles.DAY_MS
        if (days > TmdbFiles.MAX_DAYS || now() < f.lastModified()) { f.delete(); return null }
        if (days > TmdbFiles.SOFT_DAYS) return null
        return load(f)
    }

    fun isStale(name: String): Boolean = file(name).let { !it.isFile || age(it) >= GenreShelves.refetchHours(name) * 3_600_000L }

    private fun movies(path: String, query: String) = TmdbTrendingFetcher.parse(auth.call(path, query, fetch), "movie")
    private fun tv(path: String, query: String) = TmdbTrendingFetcher.parse(auth.call(path, query, fetch), "tv")

    private fun download(name: String): List<TrendingEntry>? {
        if (name == "top") return interleave(movies("movie/top_rated", "page=1") + movies("movie/top_rated", "page=2").map { it.copy(rank = it.rank + 20) }, tv("tv/top_rated", "page=1") + tv("tv/top_rated", "page=2").map { it.copy(rank = it.rank + 20) })
        val (view, key) = name.split(':', limit = 2).let { if (it.size == 2) it[0] to it[1] else return null }
        val g = GenreTable.of(key) ?: return null
        if (g.tmdbMovie.isEmpty() && g.tmdbTV.isEmpty()) return null
        val sort = if (view == "top") "sort_by=vote_average.desc" else if (view == "week") "sort_by=popularity.desc" else return null
        fun q(ids: List<Int>, votes: Int) = "with_genres=${ids.joinToString("%7C")}&$sort&include_adult=false" + (if (view == "top") "&vote_count.gte=$votes" else "") + (if (g.tmdbLang.isNotEmpty()) "&with_original_language=${g.tmdbLang}" else "") + "&page=1"
        val m = if (g.tmdbMovie.isEmpty()) emptyList() else movies("discover/movie", q(g.tmdbMovie, 300))
        val t = if (g.tmdbTV.isEmpty()) emptyList() else tv("discover/tv", q(g.tmdbTV, 150))
        return interleave(m, t)
    }

    /** Fetches one list when it is missing or stale. Blocking: call off the main thread, one at a time. True when the saved copy is now fresh. A failure keeps the old copy. */
    fun refresh(name: String): Boolean {
        if (!enabled() || !auth.available) return false
        if (!isStale(name)) return true
        val list = runCatching { download(name) }.getOrNull() ?: return false
        if (list.isEmpty()) return false
        dir.mkdirs()
        file(name).writeText(buildJsonObject { put("e", buildJsonArray { list.forEach { e -> add(buildJsonObject { put("r", e.rank); put("t", e.type); put("n", e.title); e.original?.let { put("o", it) }; e.year?.let { put("y", it) } }) } }) }.toString())
        return true
    }
}
