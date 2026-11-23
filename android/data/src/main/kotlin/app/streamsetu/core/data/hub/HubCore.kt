package app.streamsetu.core.data.hub

import app.streamsetu.core.data.repo.DisplayRating
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// The metadata hub, pure part (the same rules and numbers as the Apple app; shared cases in artwork/fixtures). No network, no database, no clock except what is passed in.
// Provider names are internal: nothing here is shown to a person outside Settings and About .

enum class HubSource(val key: String, val tieRank: Int) {
    PLAYLIST("playlist", 0), TMDB("tmdb", 1), FANART("fanart", 2), TVDB("tvdb", 3), TVMAZE("tvmaze", 4);
    companion object { fun of(key: String?) = entries.firstOrNull { it.key == key } }
}
enum class HubTitleKind(val key: String) { MOVIE("movie"), SERIES("series") }
enum class ArtKind(val key: String) { POSTER("poster"), BACKDROP("backdrop"), LOGO("logo"), BANNER("banner"), THUMB("thumb"), SEASON_POSTER("seasonPoster"), EPISODE_STILL("episodeStill");
    companion object { fun of(key: String) = entries.firstOrNull { it.key == key } }
}

data class ArtCandidate(
    val kind: ArtKind, val url: String, val source: HubSource,
    /** ISO 639-1, or "", "00", null for textless. */
    val lang: String?, val width: Int, val height: Int, val likes: Int = 0, val season: Int? = null,
)
data class ArtContext(val preferredLang: String = "en", val originalLang: String? = null, val largeScreen: Boolean = true)

object QualityScorer {
    fun isTextless(l: String?) = l == null || l == "" || l == "00" || l == "xx"
    fun languageScore(lang: String?, ctx: ArtContext): Double {
        val l = lang?.lowercase()
        if (l != null && !isTextless(l)) {
            if (l == ctx.preferredLang.lowercase()) return 1000.0
            if (ctx.originalLang?.lowercase() == l) return 500.0
            if (l == "en") return 400.0
            return 0.0
        }
        return 600.0
    }
    /** Log scale, capped at 100. */
    fun likesBucket(n: Int): Double = min(100.0, 25 * (ln(1.0 + max(0, n)) / ln(2.0)))
    fun aspect(c: ArtCandidate): Double = if (c.height > 0) c.width.toDouble() / c.height else 0.0
    fun near(a: Double, target: Double, tol: Double = 0.08) = target > 0 && abs(a - target) / target <= tol

    fun poster(c: ArtCandidate, ctx: ArtContext): Double {
        var s = languageScore(c.lang, ctx) + min(c.width, 2000) / 20.0 + likesBucket(c.likes)
        if (!near(aspect(c), 2.0 / 3.0)) s -= 300
        if (c.width < 500) s -= 500
        return s
    }
    fun logo(c: ArtCandidate, ctx: ArtContext): Double {
        if (!c.url.lowercase().endsWith(".png")) return -10_000.0
        var s = languageScore(c.lang, ctx) + min(c.width, 1500) / 30.0 + likesBucket(c.likes)
        if (c.width < 400) s -= 500
        when (c.source) { HubSource.FANART -> s += 60; HubSource.TMDB -> s += 30; else -> Unit }
        return s
    }
    fun backdrop(c: ArtCandidate, ctx: ArtContext): Double {
        if (!isTextless(c.lang) || !near(aspect(c), 16.0 / 9.0) || c.width < 1920) return -10_000.0
        var s = min(c.width, 3840) / 20.0 + likesBucket(c.likes)
        if (!ctx.largeScreen && c.width > 2600) s -= 150
        return s
    }
    fun generic(c: ArtCandidate, ctx: ArtContext): Double =
        languageScore(c.lang, ctx) / 2 + min(c.width, 2000) / 20.0 + likesBucket(c.likes) - (if (c.width < 300) 300 else 0)
    fun score(c: ArtCandidate, ctx: ArtContext): Double = when (c.kind) {
        ArtKind.POSTER -> poster(c, ctx); ArtKind.LOGO -> logo(c, ctx); ArtKind.BACKDROP -> backdrop(c, ctx); else -> generic(c, ctx)
    }
    fun usable(c: ArtCandidate, ctx: ArtContext) = score(c, ctx) > -5_000
}

data class StoredFact(val value: String, val source: HubSource, val quality: Double, val expiresAt: Long, val failCount: Int = 0) {
    val pinned: Boolean get() = quality.isInfinite()
}

object Arbiter {
    const val MARGIN = 50.0
    const val MAX_FAILURES = 2
    data class Pick(val candidate: ArtCandidate, val score: Double)

    /** The best usable candidate of a kind; ties go to TMDB, then fanart, then TheTVDB, then list order. */
    fun pick(kind: ArtKind, all: List<ArtCandidate>, ctx: ArtContext, season: Int? = null): Pick? =
        all.withIndex().filter { (_, c) -> c.kind == kind && (season == null || c.season == season) && QualityScorer.usable(c, ctx) }
            .map { (i, c) -> Triple(i, c, QualityScorer.score(c, ctx)) }
            .minWithOrNull(compareBy<Triple<Int, ArtCandidate, Double>>({ -it.third }, { it.second.source.tieRank }, { it.first }))
            ?.let { Pick(it.second, it.third) }

    fun shouldReplace(stored: StoredFact?, pick: Pick, now: Long): Boolean {
        val s = stored ?: return true
        if (s.pinned) return false
        if (s.source == HubSource.PLAYLIST) return false
        if (s.expiresAt <= now || s.failCount >= MAX_FAILURES) return true
        return pick.score > s.quality + MARGIN
    }
    fun targetQuality(kind: ArtKind): Double = when (kind) { ArtKind.POSTER -> 1075.0; ArtKind.LOGO -> 1060.0; ArtKind.BACKDROP -> 96.0; else -> 150.0 }
    fun atTarget(kind: ArtKind, stored: StoredFact?, now: Long): Boolean {
        val s = stored ?: return false
        if (s.pinned || s.source == HubSource.PLAYLIST) return true
        return s.expiresAt > now && s.failCount < MAX_FAILURES && s.quality >= targetQuality(kind)
    }
}

/** The rating a title shows: always DisplayRating (never a blend). TVmaze's average (no vote count) can only stand in behind the playlist's own. */
object RatingArbiter {
    fun value(tmdbAverage: Double?, tmdbVotes: Int?, playlist: String?, tvmaze: Double? = null): Double? {
        val fallback = if (DisplayRating.credibleProvider(playlist) != null) playlist else tvmaze?.toString()
        return DisplayRating.value(tmdbAverage, tmdbVotes, fallback)
    }
}

object EpisodeTextArbiter {
    data class Candidate(val source: HubSource, val text: String)
    private val placeholders = setOf("", "no description", "no description available", "no overview", "no overview available", "n/a", "na", "tba", "tbd", "none", "-", "null", "description")
    fun rank(s: HubSource) = when (s) { HubSource.TMDB -> 0; HubSource.TVDB -> 1; HubSource.TVMAZE -> 2; else -> 3 }
    fun isJunk(t: String?) = (t ?: "").trim().lowercase() in placeholders
    fun stripHtml(s: String): String {
        var out = s.replace(Regex("<[^>]+>"), "")
        for ((a, b) in listOf("&amp;" to "&", "&quot;" to "\"", "&#39;" to "'", "&apos;" to "'", "&nbsp;" to " ", "&lt;" to "<", "&gt;" to ">")) out = out.replace(a, b)
        return out.trim()
    }
    /** The text to store, or null to leave the stored text alone. [storedSource] is null for text from the playlist. */
    fun choose(stored: String?, storedSource: HubSource?, candidates: List<Candidate>): Candidate? {
        val clean = candidates.map { Candidate(it.source, stripHtml(it.text)) }.filter { !isJunk(it.text) }.sortedBy { rank(it.source) }
        val best = clean.firstOrNull() ?: return null
        val s = (stored ?: "").trim()
        if (isJunk(s)) return best
        if (storedSource == null || storedSource == HubSource.PLAYLIST) return null
        if (s.length < 20) clean.firstOrNull { it.text.length > 80 && rank(it.source) < rank(storedSource) }?.let { return it }
        return null
    }
}

data class HubIdentity(val tmdb: Int? = null, val tvdb: Int? = null, val imdb: String? = null, val tvmaze: Int? = null, val kind: HubTitleKind? = null) {
    val isEmpty: Boolean get() = tmdb == null && tvdb == null && imdb == null && tvmaze == null
    fun queryId(source: HubSource, kind: HubTitleKind): String? = when {
        source == HubSource.FANART && kind == HubTitleKind.MOVIE -> tmdb?.toString() ?: imdb
        source == HubSource.FANART -> tvdb?.toString()
        source == HubSource.TVDB -> tvdb?.toString()
        source == HubSource.TVMAZE -> tvmaze?.toString() ?: tvdb?.let { "tvdb:$it" } ?: imdb?.let { "imdb:$it" }
        source == HubSource.TMDB -> tmdb?.toString()
        else -> null
    }
    companion object {
        private val IMDB = Regex("^tt\\d{6,10}$")
        fun imdbId(s: String?): String? = s?.trim()?.takeIf { IMDB.matches(it) }
        fun rank(s: HubSource) = when (s) { HubSource.PLAYLIST -> 0; HubSource.TMDB -> 1; HubSource.TVDB -> 2; HubSource.TVMAZE -> 3; HubSource.FANART -> 4 }
        /** Fills gaps only: a stored id is replaced only by a lower rank number (the playlist's own ids). */
        fun merge(existing: HubIdentity, incoming: HubIdentity, incomingRank: Int, existingRank: Int): HubIdentity {
            fun <T> take(e: T?, i: T?): T? = if (i == null) e else if (e == null) i else if (incomingRank < existingRank) i else e
            return existing.copy(
                tmdb = take(existing.tmdb, incoming.tmdb?.takeIf { it > 0 }), tvdb = take(existing.tvdb, incoming.tvdb?.takeIf { it > 0 }),
                imdb = take(existing.imdb, imdbId(incoming.imdb)), tvmaze = take(existing.tvmaze, incoming.tvmaze?.takeIf { it > 0 }), kind = existing.kind ?: incoming.kind)
        }
    }
}

/** Compile-time choices. TheTVDB's built-in key is ON by default (owner's decision; TheTVDB's written approval is still pending: if it objects, flip this one constant to false). */
object HubDefaults {
    const val FANART_BUILT_IN_DEFAULT_ON = true
    const val TVDB_BUILT_IN_DEFAULT_ON = true
    const val TVMAZE_DEFAULT_ON = true
    /** Credits live in Settings only: no provider name appears on a content screen, so this stays false. */
    const val TVDB_ATTRIBUTION_ON_SCREENS = false
}

object HubAttribution {
    const val TVDB_FOOTER = "Data from TheTVDB.com"
    const val TVDB_LINK = "https://thetvdb.com"
    const val FANART_CREDIT = "Artwork from fanart.tv."
    const val FANART_LINK = "https://fanart.tv"
    const val TVMAZE_CREDIT = "Episode and schedule data from TVmaze (https://www.tvmaze.com), licensed under Creative Commons Attribution-ShareAlike 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). TVmaze text is not included in shared exports."
    /** The credit for About and Settings (not an on-screen footer; there is none): the wording of legal/licenses.md. */
    const val TVDB_CREDIT = "Metadata provided by TheTVDB.com. Please consider adding missing information or subscribing."
    const val WIKIDATA_CREDIT = "Aliases: Wikidata, CC0 (wikidata.org)."
    const val IPTV_ORG_CREDIT = "Channel logos and genres from the iptv-org public channel database (github.com/iptv-org)."
    const val OPENSUBTITLES_CREDIT = "Subtitles from OpenSubtitles (opensubtitles.com)."
    const val KEEP_NOTE = "Saved details are kept for at most 180 days (7 days for TheTVDB) and removed when you switch a source off."
    const val PRIVACY = "These extra sources are only sent a numeric id (never a title, your history or anything about this device), and only for titles you open or see; titles in locked or hidden folders are never sent. The images come from their own servers, which see your network address like any website."
    fun footer(provenance: Set<HubSource>, onScreens: Boolean = HubDefaults.TVDB_ATTRIBUTION_ON_SCREENS): String? =
        if (onScreens && HubSource.TVDB in provenance) TVDB_FOOTER else null
}

/** What one source may be asked, and how fast. fanart.tv: express lane only, never bulk (its terms). TheTVDB: stored data kept 7 days. */
data class HubPolicy(val burst: Int, val refillPerSecond: Double, val bulkAllowed: Boolean, val bulkWorkers: Int, val perRunCap: Int, val perDayCap: Int, val keepMs: Long) {
    companion object {
        const val DAY = app.streamsetu.core.data.repo.TmdbFiles.DAY_MS
        /** The retention limit TMDB's terms allow (6 months), the same constant as the files the app keeps. */
        const val TMDB_KEEP_MS = app.streamsetu.core.data.repo.TmdbFiles.MAX_DAYS * DAY
        /** TMDB has no bucket of its own here: every TMDB request goes through the app's one shared pacer (RequestPacer, its express lane for what the person sees). Only the retention applies. */
        val TMDB = HubPolicy(0, 0.0, false, 0, 0, 0, TMDB_KEEP_MS)
        val FANART = HubPolicy(2, 2.0, false, 0, 150, 300, TMDB_KEEP_MS)
        val TVDB = HubPolicy(4, 2.0, true, 1, 300, 1500, 7 * DAY)
        /** Burst 5 then 0.5/s: no 10 s window holds more than 10 calls. */
        val TVMAZE = HubPolicy(5, 0.5, true, 1, 200, 2000, TMDB_KEEP_MS)
        fun of(s: HubSource) = when (s) { HubSource.TMDB, HubSource.PLAYLIST -> TMDB; HubSource.FANART -> FANART; HubSource.TVDB -> TVDB; HubSource.TVMAZE -> TVMAZE }
    }
}

/** Token bucket with an injected clock (milliseconds). */
class TokenBucket(private val capacity: Double, private val refillPerSecond: Double, now: Long) {
    constructor(p: HubPolicy, now: Long) : this(p.burst.toDouble(), p.refillPerSecond, now)
    private var tokens = capacity
    private var last = now
    /** Takes one token and returns 0, or the milliseconds to wait (nothing taken). */
    fun take(now: Long): Long {
        val dt = max(0L, now - last) / 1000.0
        tokens = min(capacity, tokens + dt * refillPerSecond); last = max(last, now)
        if (tokens >= 1) { tokens -= 1; return 0 }
        return Math.ceil((1 - tokens) / refillPerSecond * 1000).toLong()
    }
}

class CircuitBreaker {
    private var failures = 0
    private var openUntil = -1L
    private var halfOpen = false
    private var probing = false
    fun allow(now: Long): Boolean {
        if (halfOpen) { if (probing) return false; probing = true; return true }
        if (openUntil >= 0) { if (now >= openUntil) { halfOpen = true; probing = true; return true }; return false }
        return true
    }
    fun success() { failures = 0; openUntil = -1; halfOpen = false; probing = false }
    fun failure(now: Long) {
        probing = false; failures += 1
        if (halfOpen || failures >= THRESHOLD) { openUntil = now + OPEN_MS; halfOpen = false }
    }
    companion object { const val THRESHOLD = 5; const val OPEN_MS = 15 * 60_000L }
}

object NegativeCache {
    sealed class Outcome { object NotFound : Outcome(); object ServerError : Outcome(); object Offline : Outcome(); object Ok : Outcome(); data class RateLimited(val retryAfterSec: Double?) : Outcome() }
    const val NOT_FOUND_MS = 30L * 86_400_000
    const val SERVER_ERROR_MS = 6L * 3_600_000
    fun missUntil(o: Outcome, now: Long): Long? = when (o) {
        Outcome.NotFound -> now + NOT_FOUND_MS
        Outcome.ServerError -> now + SERVER_ERROR_MS
        Outcome.Offline, Outcome.Ok -> null
        is Outcome.RateLimited -> now + (min(max(o.retryAfterSec ?: 10.0, 1.0), 900.0) * 1000).toLong()
    }
    fun outcome(status: Int, retryAfterSec: Double?): Outcome = when (status) { 404 -> Outcome.NotFound; 429 -> Outcome.RateLimited(retryAfterSec); else -> Outcome.ServerError }
    fun backoffSeconds(retryAfterSec: Double?, previousFailures: Int): Double =
        if (retryAfterSec != null && retryAfterSec > 0) min(retryAfterSec, 900.0) else min(900.0, 10 * 2.0.pow(max(0, previousFailures)))
}

enum class HubLane { EXPRESS, BULK }

/** The queue of one source: express before bulk, de-duplicated, one express request in flight, caps per run and per day; a source that forbids bulk refuses it. */
class HubQueue(private val policy: HubPolicy, now: Long) {
    private val express = ArrayDeque<String>()
    private val bulk = ArrayDeque<String>()
    private val inFlightExpress = mutableSetOf<String>()
    private val inFlightBulk = mutableSetOf<String>()
    private var doneThisRun = 0
    private var dayStart = dayOf(now)
    private var doneToday = 0
    private fun dayOf(t: Long) = t / HubPolicy.DAY

    fun enqueue(key: String, lane: HubLane): Boolean {
        if (key in inFlightExpress || key in inFlightBulk) return false
        return when (lane) {
            HubLane.EXPRESS -> { bulk.remove(key); express.remove(key); express.addFirst(key); true }
            HubLane.BULK -> { if (!policy.bulkAllowed || key in express || key in bulk) false else { bulk.addLast(key); true } }
        }
    }
    fun next(now: Long): Pair<String, HubLane>? {
        if (dayOf(now) > dayStart) { dayStart = dayOf(now); doneToday = 0 }
        if (doneToday >= policy.perDayCap) return null
        if (inFlightExpress.isEmpty() && express.isNotEmpty()) { val k = express.removeFirst(); inFlightExpress += k; return k to HubLane.EXPRESS }
        if (policy.bulkAllowed && doneThisRun < policy.perRunCap && inFlightBulk.size < policy.bulkWorkers && bulk.isNotEmpty()) { val k = bulk.removeFirst(); inFlightBulk += k; return k to HubLane.BULK }
        return null
    }
    fun finish(key: String) { inFlightExpress.remove(key); inFlightBulk.remove(key); doneThisRun += 1; doneToday += 1 }
}
