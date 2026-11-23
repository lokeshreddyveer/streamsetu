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
 * What TMDB is asked for besides artwork, with the person's own key when they entered one and the app's built-in read token otherwise, and never anything about the person: only a title name
 * and year, or the public weekly trending lists. Everything fetched is kept in files of its own, shown for at most [TmdbFiles.SOFT_DAYS] days without a refresh and deleted at [TmdbFiles.MAX_DAYS] days (TMDB's six month limit).
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
        val files = dir.listFiles()?.filter { it.isFile && it.name != KEEP && it.name != TmdbAuth.OFF_FILE && !it.name.startsWith(ArtworkMatchEngine.STATE_PREFIX) }?.sortedBy { it.lastModified() } ?: return 0
        var n = 0
        for ((i, f) in files.withIndex()) if (now - f.lastModified() > maxDays * DAY_MS || i < files.size - MAX_FILES) { if (f.delete()) n++ }
        return n
    }
    /** Everything TMDB gave this device is removed (the switch turned off, the key removed, or "Clear"). */
    fun clear(dir: File) { dir.listFiles()?.filter { it.name != KEEP && it.name != TmdbAuth.OFF_FILE }?.forEach { it.delete() } }
}

class TmdbCast(private val key: () -> String?, private val dir: File, private val fetch: TmdbCall = tmdbHttp, private val now: () -> Long = System::currentTimeMillis, auth: TmdbAuth? = null, matcher: TmdbMatcher? = null) {
    data class Member(val id: Long, val name: String, val role: String?, val photo: String?)
    /** What opening a title needs from TMDB at once: the cast (with photos) and a wide picture. */
    data class Details(val cast: List<Member>, val backdrop: String?, val poster: String? = null, val plot: String? = null, val rating: Double? = null, val trailerKey: String? = null, val tmdbId: Long? = null, val genres: List<Int> = emptyList()) {
        /** The rating a title shows (see [DisplayRating]): TMDB's when enough people voted, else the provider's when it is credible, else none. */
        fun ratingOr(providerRating: String?): String? = DisplayRating.value(rating, if (rating != null) DisplayRating.TMDB_VOTE_FLOOR else null, providerRating)?.let { "%.1f".format(java.util.Locale.US, it) }
        companion object { val NONE = Details(emptyList(), null) }
    }

    val auth: TmdbAuth = auth ?: TmdbAuth(key, { null }, dir, now)
    private val matcher = matcher ?: TmdbMatcher(this.auth, fetch)

    companion object {
        const val MAX_MEMBERS = 14
        const val MISS_HOURS = 24L
        fun parseSearch(json: String): Long? = ((Xtream.parseObject(json)?.get("results") as? JsonArray)?.firstOrNull() as? JsonObject)?.get("id")?.jsonPrimitive?.longOrNull
        /** The first [MAX_MEMBERS] people in billing order, the ones with a photo first (a row of initials says little). */
        fun parseCredits(json: String): List<Member> {
            val cast = (Xtream.parseObject(json)?.get("cast") as? JsonArray) ?: return emptyList()
            val all = cast.take(40).mapNotNull { e -> (e as? JsonObject)?.let { o ->
                val name = o.str("name") ?: return@let null
                Member(o["id"]?.jsonPrimitive?.longOrNull ?: return@let null, name, o.str("character"), o.str("profile_path")?.let { "https://image.tmdb.org/t/p/w185$it" })
            } }
            return (all.filter { it.photo != null } + all.filter { it.photo == null }).take(MAX_MEMBERS)
        }
        /** A details answer (the title with its credits appended): the cast and the wide picture. */
        fun parseDetails(json: String): Details {
            val o = Xtream.parseObject(json) ?: return Details.NONE
            val trailer = ((o["videos"] as? JsonObject)?.get("results") as? JsonArray)?.mapNotNull { it as? JsonObject }?.firstOrNull { it.str("site") == "YouTube" && it.str("type") == "Trailer" }?.str("key")
            return Details(parseCredits((o["credits"] as? JsonObject)?.toString() ?: "{}"), o.str("backdrop_path")?.let { "https://image.tmdb.org/t/p/w780$it" },
                o.str("poster_path")?.let { "https://image.tmdb.org/t/p/w342$it" }, o.str("overview"), DisplayRating.credible(o["vote_average"]?.jsonPrimitive?.doubleOrNull, o["vote_count"]?.jsonPrimitive?.intOrNull), trailer, genres = (o["genres"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.get("id")?.jsonPrimitive?.intOrNull })
        }
    }

    /** True when something can be asked of TMDB: the person's own key or the built-in token. */
    val enabled get() = auth.available

    /** The cast of a title (see [details]). */
    fun cast(title: String, year: Int?, series: Boolean): List<Member> = details(title, year, series).cast

    /** True when a saved, fresh answer exists (nothing needs to be asked): read it with [details], which is then instant. */
    fun hasFresh(title: String, year: Int?, series: Boolean): Boolean = fileFor(title, year, series)?.let { fresh(it) } == true

    private fun fileFor(title: String, year: Int?, series: Boolean): File? {
        val q = ArtworkNames.parse(title, year).let { p -> TmdbService.Query(p.text, p.year) }
        if (q.title.length < 2) return null
        return File(dir, "cast-" + sha("${if (series) "tv" else "movie"}|${q.title.lowercase()}|${q.year}") + ".json")
    }
    private fun fresh(f: File): Boolean {
        if (!f.isFile) return false
        val age = now() - f.lastModified()
        val empty = runCatching { f.length() < 40 }.getOrDefault(true)
        return age < (if (empty) MISS_HOURS * 3_600_000L else TmdbFiles.SOFT_DAYS * TmdbFiles.DAY_MS)
    }

    /** The cast and wide picture of a title, from the saved copy when it is under 30 days old (a "nothing found" copy, one day). Empty with no credential, no match, or no network. Blocking: call off the main thread. */
    fun details(title: String, year: Int?, series: Boolean): Details = runCatching { detailsOrThrow(title, year, series) }.getOrDefault(Details.NONE)

    /**
     * As [details], but a request that failed is thrown (so a screen can say why), and nothing is saved for it. [onExtras] is told (series?, raw details reply) after a fresh fetch (not for a saved
     * copy): the caller that knows the library item's id hands the other services' ids in it to the hub.
     */
    fun detailsOrThrow(title: String, year: Int?, series: Boolean, onExtras: ((Boolean, String) -> Unit)? = null): Details {
        if (!auth.available) return Details.NONE
        val file = fileFor(title, year, series) ?: return Details.NONE
        if (fresh(file)) runCatching { return parseSaved(file.readText()) }
        val kind = if (series) "tv" else "movie"
        run {
            val m = matcher.match(kind, title, year)
            if (m == null) { save(file, Details.NONE); return Details.NONE }
            val raw = auth.call("$kind/${m.id}", "append_to_response=credits,images,videos,external_ids,translations", fetch)
            runCatching { onExtras?.invoke(series, raw) }          // the other services' ids go to the hub, keyed by the caller's item id
            val d = parseDetails(raw).let { it.copy(tmdbId = m.id, backdrop = it.backdrop ?: m.backdropUrl, poster = it.poster ?: m.posterUrl, plot = it.plot ?: m.plot) }
            save(file, d); return d
        }
    }

    private fun save(f: File, d: Details) {
        dir.mkdirs()
        f.writeText(buildJsonObject { d.backdrop?.let { put("b", it) }; d.poster?.let { put("pp", it) }; d.plot?.let { put("o", it) }; d.rating?.let { put("v", it) }; d.trailerKey?.let { put("t", it) }; d.tmdbId?.let { put("id", it) }; if (d.genres.isNotEmpty()) put("g", buildJsonArray { d.genres.forEach { add(it) } }); put("c", buildJsonArray { d.cast.forEach { m -> add(buildJsonObject { put("i", m.id); put("n", m.name); m.role?.let { put("r", it) }; m.photo?.let { put("p", it) } }) } }) }.toString())
    }
    private fun parseSaved(text: String): Details {
        val o = Json.parseToJsonElement(text).jsonObject
        return Details((o["c"] as? JsonArray).orEmpty().map { e -> e.jsonObject.let { Member(it["i"]!!.jsonPrimitive.long, it["n"]!!.jsonPrimitive.content, it["r"]?.jsonPrimitive?.contentOrNull, it["p"]?.jsonPrimitive?.contentOrNull) } }, o["b"]?.jsonPrimitive?.contentOrNull,
            o["pp"]?.jsonPrimitive?.contentOrNull, o["o"]?.jsonPrimitive?.contentOrNull, o["v"]?.jsonPrimitive?.doubleOrNull, o["t"]?.jsonPrimitive?.contentOrNull, o["id"]?.jsonPrimitive?.longOrNull, (o["g"] as? JsonArray).orEmpty().mapNotNull { it.jsonPrimitive.intOrNull })
    }

    private fun sha(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).take(10).joinToString("") { "%02x".format(it) }
}

/** The public weekly trending lists (movies and tv), one request each. Nothing about the person is part of the request. */
class TmdbTrendingFetcher(private val auth: TmdbAuth, private val fetch: TmdbCall = tmdbHttp) : TrendingFetcher {
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
        // [apiKey] only says that a credential exists; the request uses the one in use ([TmdbAuth]).
        val movies = parse(auth.call("trending/movie/week", "", fetch), "movie")
        val tv = parse(auth.call("trending/tv/week", "", fetch), "tv")
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
