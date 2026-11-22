package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.OverrideEntity
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.net.URLEncoder

/**
 * Fills in pictures and stories that a provider left out, from The Movie Database (https://www.themoviedb.org). It needs the person's own free API key, only looks up titles
 * that have no picture, and saves what it finds as a local correction (the provider's data is never edited). "This product uses the TMDB API but is not endorsed or certified by TMDB."
 */
class TmdbService(private val db: AppDatabase, private val key: () -> String?, private val visibility: Visibility? = null, private val dir: java.io.File? = null, private val now: () -> Long = System::currentTimeMillis, private val fetch: (String) -> String = { Http.text(it) }) {
    data class Query(val title: String, val year: Int?)
    data class Found(val posterUrl: String?, val plot: String?)

    companion object {
        /** "Heat (1995) [FHD] ᴴᴰ" to ("Heat", 1995). Brackets, quality tags and the year in the name are taken out of the search. */
        fun query(raw: String, knownYear: Int?): Query {
            var t = raw
            val year = Regex("[(\\[]((?:19|20)\\d\\d)[)\\]]").find(t)?.groupValues?.get(1)?.toIntOrNull() ?: knownYear
            t = t.replace(Regex("[(\\[][^)\\]]*[)\\]]"), " ")
            t = t.replace(Regex("(?i)\\b(4k|uhd|fhd|hd|sd|hevc|x26[45]|h26[45]|1080p|720p|2160p|bluray|web-?dl|multi|dual)\\b"), " ")
            t = t.replace(Regex("^[A-Za-z]{2,3}\\s*[|:-]\\s*"), "")          // a country or language prefix: "EN | Heat"
            return Query(t.replace(Regex("\\s+"), " ").trim(), year)
        }

        fun parse(json: String): Found? {
            val first = ((Xtream.parseObject(json)?.get("results") as? JsonArray)?.firstOrNull() as? JsonObject) ?: return null
            return Found(first.str("poster_path")?.let { "https://image.tmdb.org/t/p/w342$it" }, first.str("overview"))
        }
    }

    private fun lookup(kind: String, q: Query, apiKey: String): Found? {
        val url = "https://api.themoviedb.org/3/search/$kind?api_key=${URLEncoder.encode(apiKey, "UTF-8")}&query=${URLEncoder.encode(q.title, "UTF-8")}" +
            (q.year?.let { if (kind == "movie") "&year=$it" else "&first_air_date_year=$it" } ?: "")
        return parse(fetch(url))
    }

    // Which titles TMDB filled, and when (a file of its own: the correction rows carry no time). Used for the 180-day limit and for taking back what a lock or hide covers.
    private val log get() = dir?.let { java.io.File(it, "filled.log") }
    private fun readLog(): LinkedHashMap<String, Long> = LinkedHashMap<String, Long>().also { m -> runCatching { log?.takeIf { it.isFile }?.forEachLine { l -> l.split('\t').takeIf { it.size == 2 }?.let { p -> p[1].toLongOrNull()?.let { t -> m[p[0]] = t } } } } }
    private fun writeLog(m: Map<String, Long>) { log?.let { f -> f.parentFile?.mkdirs(); if (m.isEmpty()) f.delete() else f.writeText(m.entries.joinToString("\n") { "${it.key}\t${it.value}" }) } }

    /**
     * Looks up to [limit] titles without a picture; returns how many got one. [onProgress] is told (done, total). A title in a locked, hidden or adult-blocked folder, or with a copy in one
     * (the strictest rule, [Visibility.Surface.RECOMMEND]), is never listed for matching and never sent to TMDB.
     */
    suspend fun fillMissing(limit: Int = 150, onProgress: (Int, Int) -> Unit = { _, _ -> }): Int = withContext(Dispatchers.IO) {
        val apiKey = key()?.takeIf { it.isNotBlank() } ?: error("Enter your TMDB API key first.")
        failedAt?.let { at -> if (now() - at < TmdbFiles.DAY_MS / 24) error("TMDB could not be reached a moment ago. Try again in a little while.") else failedAt = null }
        val extras = db.extras()
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        // Read more than needed so the restricted ones in front do not use up the allowance.
        val movies = extras.moviesWithoutPoster(limit * 6).filter { snap == null || snap.movieOk(it.toModel()) }.take(limit)
        val series = extras.seriesWithoutPoster(limit * 6).filter { snap == null || snap.seriesOk(it.toModel()) }.take((limit - movies.size).coerceAtLeast(0))
        val total = movies.size + series.size
        var done = 0; var filled = 0
        val filledAt = readLog()
        var failures = 0
        suspend fun one(id: String, title: String, year: Int?, kind: String): Boolean {
            // Only an answer from TMDB counts: no match is remembered (so it is not asked again and again), but a network failure is not a "no match": nothing is stored and the title is asked again later.
            val found = try { lookup(kind, query(title, year), apiKey) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                failures++
                if (failures >= 3) { failedAt = now(); return false }          // three failures in a run: stop, and wait before trying again
                onProgress(++done, total); delay(120); return true               // this title is left as it was and is asked again later
            }
            // The record comes first: if the run is stopped right after the correction is written, it can still be taken back (a lock, the 180-day limit).
            filledAt[id] = now(); writeLog(filledAt)
            extras.putOverride(OverrideEntity(id, null, found?.posterUrl, found?.plot))
            if (found?.posterUrl != null) filled++
            onProgress(++done, total); delay(120)
            return true
        }
        for (m in movies) if (!one(m.id, m.title, m.year, "movie")) break
        if (failedAt == null) for (sr in series) if (!one(sr.id, sr.title, sr.year, "tv")) break
        writeLog(filledAt)
        if (failedAt != null) error("TMDB could not be reached. Nothing was marked as unmatched; try again later.")
        filled
    }

    /** A moment of backoff after TMDB could not be reached: the next run waits an hour. */
    @Volatile private var failedAt: Long? = null

    /** What TMDB filled in (a picture, a summary) is taken back for titles that are now restricted, and for anything older than 180 days. Returns how many were removed. A correction the person made by hand is never touched. */
    suspend fun purge(): Int = withContext(Dispatchers.IO) {
        val extras = db.extras()
        val filledAt = readLog()
        if (filledAt.isEmpty()) return@withContext 0
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        val cutoff = now() - TmdbFiles.MAX_DAYS * TmdbFiles.DAY_MS
        val movies = filledAt.keys.toList().chunked(400).flatMap { extras.moviesByIds(it) }.associateBy { it.id }
        val series = filledAt.keys.toList().chunked(400).flatMap { extras.seriesByIds(it) }.associateBy { it.id }
        var n = 0
        for ((id, at) in filledAt.entries.toList()) {
            val restricted = snap != null && (movies[id]?.let { !snap.movieOk(it.toModel()) } ?: series[id]?.let { !snap.seriesOk(it.toModel()) } ?: false)
            val gone = movies[id] == null && series[id] == null
            if (at < cutoff || restricted || gone) { extras.clearTmdbOverride(id); filledAt.remove(id); n++ }
        }
        writeLog(filledAt)
        n
    }
}
