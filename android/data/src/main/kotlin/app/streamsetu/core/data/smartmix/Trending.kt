package app.streamsetu.core.data.smartmix

import java.text.Normalizer
import java.util.Locale

/** One entry of TMDB's PUBLIC weekly trending list. Nothing about the user is part of it. */
data class TrendingEntry(val rank: Int, val type: String /* "movie" | "tv" */, val title: String, val original: String? = null, val year: Int? = null)
data class TrendingSnapshot(val fetchedAtMillis: Long, val entries: List<TrendingEntry>)

interface TrendingFetcher {
    /** One request for the public weekly trending lists (movies, tv) with the person's own key. Null on offline / rate limit / error. */
    fun fetchWeekly(apiKey: String): TrendingSnapshot?
}

interface TrendingCacheStore {
    fun load(): TrendingSnapshot?
    fun save(snapshot: TrendingSnapshot)
    fun clear()
}

class InMemoryTrendingCache : TrendingCacheStore {
    private var snap: TrendingSnapshot? = null
    override fun load() = snap
    override fun save(snapshot: TrendingSnapshot) { snap = snapshot }
    override fun clear() { snap = null }
}

interface TmdbSettings {
    /** "Use TMDB weekly trending": ON by default. Only effective together with [userKey]. */
    val trendingEnabled: Boolean
    /** Null means no TMDB credential at all (local mix only); any other value only says one exists: requests use the credential in use (the person's own key, else the built-in token). */
    val userKey: String?
}

data class FixedTmdbSettings(override val trendingEnabled: Boolean = true, override val userKey: String? = null) : TmdbSettings

/** What the shelves see: a status (off | noCache | purged | expired | active) and, when active, the entries. */
class TrendingView(val status: String, val entries: List<TrendingEntry>?) {
    companion object { val OFF = TrendingView("off", null) }
}

object TrendingPolicy {
    const val DAY_MS = app.streamsetu.core.data.repo.TmdbFiles.DAY_MS
    /** Quiet refresh once the cached list is a week old (it is a weekly list). */
    const val REFRESH_AFTER_DAYS = 7
    /** Used for Top This Week only while at most 30 days old. */
    const val DISPLAY_DAYS = 30
    /** Stored TMDB data is purged after 180 days at the latest (6 month limit). */
    const val MAX_DAYS = app.streamsetu.core.data.repo.TmdbFiles.MAX_DAYS
    const val RETRY_AFTER_FAILURE_MS = 3_600_000L

    fun view(enabled: Boolean, keyPresent: Boolean, cacheAgeDays: Int?, entries: List<TrendingEntry>?): TrendingView {
        if (!(enabled && keyPresent)) return TrendingView.OFF
        return when {
            cacheAgeDays == null || entries == null -> TrendingView("noCache", null)
            cacheAgeDays > MAX_DAYS -> TrendingView("purged", null)
            cacheAgeDays > DISPLAY_DAYS -> TrendingView("expired", null)
            else -> TrendingView("active", entries)
        }
    }
}

fun interface TrendingViewSource { fun view(nowMillis: Long): TrendingView }

/** Owns the fetch / cache decision. Active only with the person's own key and the switch on; otherwise the cache is purged. */
class TrendingProvider(private val settings: TmdbSettings, private val fetcher: TrendingFetcher, private val cache: TrendingCacheStore) : TrendingViewSource {
    private var lastFailureAt = Long.MIN_VALUE

    /** May block on the network: call off the main thread. */
    @Synchronized
    override fun view(nowMillis: Long): TrendingView {
        val key = settings.userKey
        if (!settings.trendingEnabled || key.isNullOrBlank()) { cache.clear(); return TrendingView.OFF }
        var snap = cache.load()
        fun ageDays(s: TrendingSnapshot) = ((nowMillis - s.fetchedAtMillis) / TrendingPolicy.DAY_MS).toInt()
        if (snap != null && (nowMillis < snap.fetchedAtMillis || ageDays(snap) > TrendingPolicy.MAX_DAYS)) { cache.clear(); snap = null }
        val due = snap == null || ageDays(snap) >= TrendingPolicy.REFRESH_AFTER_DAYS
        if (due && (lastFailureAt == Long.MIN_VALUE || nowMillis - lastFailureAt >= TrendingPolicy.RETRY_AFTER_FAILURE_MS)) {
            val fresh = runCatching { fetcher.fetchWeekly(key) }.getOrNull()
            if (fresh != null && fresh.entries.isNotEmpty()) {
                snap = fresh.copy(fetchedAtMillis = nowMillis); cache.save(snap); lastFailureAt = Long.MIN_VALUE
            } else lastFailureAt = nowMillis
        }
        return if (snap == null) TrendingView("noCache", null) else TrendingPolicy.view(true, true, ageDays(snap), snap.entries)
    }
}

/** Matches the public list against the local library only; entries with no local match are dropped silently. */
object TrendingMatcher {
    /** NFKD, drop combining marks (canonical class != 0), lowercase, keep a-z 0-9 and every non-ASCII code point, one leading article dropped. Same on every platform. */
    fun fold(title: String): String {
        val d = Normalizer.normalize(title, Normalizer.Form.NFKD)
        val sb = StringBuilder()
        var i = 0
        while (i < d.length) {
            val cp = d.codePointAt(i); i += Character.charCount(cp)
            if (CombiningClass.isCombining(cp)) continue
            sb.appendCodePoint(cp)
        }
        val low = sb.toString().lowercase(Locale.ROOT)
        val out = StringBuilder()
        i = 0
        while (i < low.length) {
            val cp = low.codePointAt(i); i += Character.charCount(cp)
            if ((cp in 0x30..0x39) || (cp in 0x61..0x7A) || cp >= 0x80) out.appendCodePoint(cp) else out.append(' ')
        }
        var words = out.toString().split(' ').filter { it.isNotEmpty() }
        if (words.isNotEmpty() && words[0] in setOf("the", "a", "an") && words.size > 1) words = words.drop(1)
        return words.joinToString(" ")
    }

    /** candidate id -> best (lowest) TMDB rank. */
    fun match(entries: List<TrendingEntry>, cands: List<Candidate>): Map<String, Int> {
        val idx = HashMap<String, MutableList<Candidate>>()
        for (c in cands) idx.getOrPut(c.kind.ordinal.toString() + "|" + c.identityKey) { ArrayList(1) }.add(c)
        val res = HashMap<String, Int>()
        for (e in entries.sortedBy { it.rank }) {
            val kind = if (e.type == "movie") Kind.MOVIE else Kind.SERIES
            val names = java.util.TreeSet<String>(); names.add(fold(e.title)); e.original?.takeIf { it.isNotEmpty() }?.let { names.add(fold(it)) }
            for (nm in names) {
                for (c in idx[kind.ordinal.toString() + "|" + nm] ?: continue) {
                    val ey = e.year; val cy = c.year
                    if (ey != null && cy != null && Math.abs(ey - cy) > 1) continue
                    if (c.id !in res) res[c.id] = e.rank
                }
            }
        }
        return res
    }
}
