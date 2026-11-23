package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.OverrideEntity
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.net.URLEncoder

/**
 * Fills in pictures and stories that a provider left out, from The Movie Database (https://www.themoviedb.org). Only a title's name and year are sent, never for a restricted title; the
 * credential is the person's own key when there is one, else the app's built-in read token ([TmdbAuth]). What it finds is saved as a local correction (the provider's data is never
 * edited). The run itself is [ArtworkMatchEngine]. "This product uses the TMDB API but is not endorsed or certified by TMDB."
 */
class TmdbService(private val db: AppDatabase, private val key: () -> String?, private val visibility: Visibility? = null, private val dir: java.io.File? = null, private val now: () -> Long = System::currentTimeMillis, auth: TmdbAuth? = null, private val fetch: TmdbCall = tmdbHttp) {
    data class Query(val title: String, val year: Int?)
    data class Found(val posterUrl: String?, val plot: String?)
    enum class Outcome { FOUND, NOT_FOUND }

    val auth: TmdbAuth = auth ?: TmdbAuth(key, { null }, dir, now)
    /** The TMDB id the provider itself listed for a library item (item id to id), when the app has it: such a title is fetched by that id, with no search. */
    @Volatile var providerTmdbId: (String) -> Long? = { null }
    /** The library's language for a title ("Telugu"), when known: it breaks ties between films of one name. */
    @Volatile var languageOf: (String) -> String = { "" }
    /** Where the TMDB id of every matched title is kept (see [TmdbIdStore]); set by the app. */
    @Volatile var idStore: TmdbIdStore? = null
    val matcher = TmdbMatcher(this.auth, fetch)
    /** The shipped offline alias index (assets/aliases/aliases.tsv.gz), read on first use; set by the app. */
    var aliasSource: (() -> ByteArray?)? by matcher::aliasSource

    companion object {
        /** "Heat (1995) [FHD] ᴴᴰ" to ("Heat", 1995): the light first-try cleaning. [ArtworkNames.clean] is the thorough second try. */
        fun query(raw: String, knownYear: Int?): Query {
            var t = ArtworkNames.normalizeText(raw).replace(Regex("[\\u0001]"), " ")
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

    // Which titles TMDB was asked about, and when (a file of its own: the correction rows carry no time). Used for the 180-day limit, for progress, and for taking back what a lock or hide covers.
    // One line per title, appended as it happens ("id<TAB>time", plus "<TAB>n" when TMDB had no match); a later line for the same title wins. Rewritten whole only by [purge].
    private val log get() = dir?.let { java.io.File(it, "filled.log") }
    private val logLock = Any()
    /** id to (time, notFound) */
    private fun readLogFull(): LinkedHashMap<String, Pair<Long, Boolean>> = LinkedHashMap<String, Pair<Long, Boolean>>().also { m -> synchronized(logLock) { runCatching { log?.takeIf { it.isFile }?.forEachLine { l -> val p = l.split('\t'); if (p.size >= 2) p[1].toLongOrNull()?.let { t -> m[p[0]] = t to (p.getOrNull(2) == "n") } } } } }
    private fun writeLog(m: Map<String, Pair<Long, Boolean>>) { synchronized(logLock) { log?.let { f -> f.parentFile?.mkdirs(); if (m.isEmpty()) f.delete() else f.writeText(m.entries.joinToString("\n") { "${it.key}\t${it.value.first}" + (if (it.value.second) "\tn" else "") } + "\n") } } }
    private fun appendLog(id: String, at: Long, notFound: Boolean) { synchronized(logLock) { log?.let { f -> f.parentFile?.mkdirs(); f.appendText("$id\t$at" + (if (notFound) "\tn" else "") + "\n") } } }

    /** Asks TMDB for its settings with the credential in use: the answer to "Test key". Blocking. */
    fun test(): String = try { auth.call("configuration", "", fetch); "Works." } catch (e: app.streamsetu.core.net.HttpStatusException) {
        if (e.code == 401 || e.code == 403) "TMDB did not accept this key." else if (e.code == 429) "TMDB is busy; try again in a moment." else "TMDB answered with an error (${e.code})."
    } catch (e: java.io.IOException) { if (auth.available) "Could not reach TMDB." else "There is no key to test." }

    /** (titles asked about so far, of which TMDB had no match). */
    fun counts(): Pair<Int, Int> { val m = readLogFull(); return m.size to m.values.count { it.second } }
    /** The titles TMDB had no match for. */
    fun notFoundIds(): List<String> = readLogFull().filter { it.value.second }.keys.toList()
    /** Forget "no match" for these titles (the matching rules changed): their blank corrections are removed so they are asked again. */
    suspend fun forgetNotFound(ids: List<String>) { val extras = db.extras(); val m = readLogFull(); for (id in ids) { extras.clearTmdbOverride(id); m.remove(id) }; writeLog(m) }

    /**
     * Asks TMDB about one title and keeps the answer: a correction with the picture and summary, or an empty correction ("no match", so it is not asked again and again). A network
     * failure is thrown and nothing is stored. The caller has already checked that the title may be sent. [plotOnly]: the provider has a picture, so only the summary is taken.
     */
    suspend fun matchOne(id: String, title: String, year: Int?, kind: String, plotOnly: Boolean = false): Outcome {
        val (outcome, row) = lookup(id, title, year, kind, plotOnly)
        db.extras().putOverride(row)
        return outcome
    }

    /** Keeps what an opened title's details gave (a picture, a summary) as the correction, with the record, exactly as a match would. */
    suspend fun store(id: String, poster: String?, plot: String?, tmdbId: Long? = null, tv: Boolean = false) {
        if (tmdbId != null) idStore?.put(id, tmdbId, tv)
        appendLog(id, now(), poster == null && plot == null); db.extras().putOverride(OverrideEntity(id, null, poster, plot)) }

    /** The same, but the correction is handed back instead of written, so a run can write many in one transaction. The record of the question is made here, first. Blocking network. */
    fun lookup(id: String, title: String, year: Int?, kind: String, plotOnly: Boolean = false): Pair<Outcome, OverrideEntity> {
        val m = matcher.match(kind, title, year, languageOf(title), providerTmdbId(id))
        val hit = m != null && (if (plotOnly) m.plot != null else (m.posterUrl != null || m.plot != null))
        appendLog(id, now(), !hit && !plotOnly && !TmdbMatcher.isNonTitle(title, year))          // a summary-only miss for a title that already has its picture is not an artwork miss
        if (hit && m != null) idStore?.put(id, m.id, kind == "tv")
        return (if (hit) Outcome.FOUND else Outcome.NOT_FOUND) to OverrideEntity(id, null, if (plotOnly) null else m?.posterUrl, m?.plot)
    }

    /**
     * The older one-shot pass, up to [limit] titles without a picture (kept for callers that want exactly that); the background run is [ArtworkMatchEngine]. [onProgress] is told (done, total).
     * A restricted title (the strictest rule, [Visibility.Surface.RECOMMEND]) is never listed for matching and never sent to TMDB.
     */
    suspend fun fillMissing(limit: Int = 150, onProgress: (Int, Int) -> Unit = { _, _ -> }): Int = withContext(Dispatchers.IO) {
        if (!auth.available) error("TMDB is not available: no key.")
        failedAt?.let { at -> if (now() - at < TmdbFiles.DAY_MS / 24) error("TMDB could not be reached a moment ago. Try again in a little while.") else failedAt = null }
        val extras = db.extras()
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        // Read more than needed so the restricted ones in front do not use up the allowance.
        val movies = extras.moviesWithoutPoster(limit * 6).filter { snap == null || snap.movieOk(it.toModel()) }.take(limit)
        val series = extras.seriesWithoutPoster(limit * 6).filter { snap == null || snap.seriesOk(it.toModel()) }.take((limit - movies.size).coerceAtLeast(0))
        val total = movies.size + series.size
        var done = 0; var filled = 0
        var failures = 0
        suspend fun one(id: String, title: String, year: Int?, kind: String): Boolean {
            // Only an answer from TMDB counts; a network failure is not a "no match": nothing is stored and the title is asked again later.
            val out = try { matchOne(id, title, year, kind) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                failures++
                if (failures >= 3) { failedAt = now(); return false }          // three failures in a run: stop, and wait before trying again
                onProgress(++done, total); delay(120); return true               // this title is left as it was and is asked again later
            }
            if (out == Outcome.FOUND) filled++
            onProgress(++done, total); delay(120)
            return true
        }
        for (m in movies) if (!one(m.id, m.title, m.year, "movie")) break
        if (failedAt == null) for (sr in series) if (!one(sr.id, sr.title, sr.year, "tv")) break
        if (failedAt != null) error("TMDB could not be reached. Nothing was marked as unmatched; try again later.")
        filled
    }

    /** A moment of backoff after TMDB could not be reached: the next run waits an hour. */
    @Volatile private var failedAt: Long? = null

    /** What TMDB filled in (a picture, a summary) is taken back for titles that are now restricted, and for anything older than 180 days. Returns how many were removed. A correction the person made by hand is never touched. */
    suspend fun purge(): Int = withContext(Dispatchers.IO) {
        val extras = db.extras()
        val filledAt = readLogFull()
        if (filledAt.isEmpty()) return@withContext 0
        val snap = visibility?.snapshot(Visibility.Surface.RECOMMEND)
        val cutoff = now() - TmdbFiles.MAX_DAYS * TmdbFiles.DAY_MS
        val movies = filledAt.keys.toList().chunked(400).flatMap { extras.moviesByIds(it) }.associateBy { it.id }
        val series = filledAt.keys.toList().chunked(400).flatMap { extras.seriesByIds(it) }.associateBy { it.id }
        var n = 0
        for ((id, pair) in filledAt.entries.toList()) { val at = pair.first
            val restricted = snap != null && (movies[id]?.let { !snap.movieOk(it.toModel()) } ?: series[id]?.let { !snap.seriesOk(it.toModel()) } ?: false)
            val gone = movies[id] == null && series[id] == null
            if (at < cutoff || restricted || gone) { extras.clearTmdbOverride(id); filledAt.remove(id); idStore?.remove(listOf(id)); extras.clearRatingChecks(listOf(id)); n++ }
        }
        extras.clearRatingChecksBefore(cutoff)
        idStore?.purgeOlderThan(cutoff)
        writeLog(filledAt)
        n
    }
}
