package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventState
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.sports.recording.SportsRecordingStatus
import app.streamsetu.tv.ui.screens.sports.SportsLoad
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * Sports results for the app's one Search list. It is not a search engine of its own: it matches the typed words against the events the Sports screens already hold (the same window, the same
 * cache, the same authorization), turns hits into ordinary [SearchItem]s, and the Search screen merges them into its list. Nothing here asks a provider, and nothing is stored: the index is made
 * in memory from the loaded events and dropped when who may see what changes.
 *
 * Order: an exact name, then a name that starts with the words, then one that contains every word; inside each, followed things, then live, then starting soon, then later events.
 */
class SportsSearch(private val source: Source, private val diagnostics: DiscoveryDiagnostics = DiscoveryDiagnostics.Log) {
    interface Source {
        fun now(): Long
        /** Who may see what, as text that changes whenever it does (profile, library, locks, filters, hidden channels). */
        suspend fun contextKey(): String
        /** The events of the hub window for this person (the Sports service answers from its cache). */
        suspend fun load(): SportsLoad
        suspend fun follows(): FollowSet
        suspend fun recordings(): List<SportsRecordingEntity>
        val zone: java.util.TimeZone
    }

    private class Name(val key: String, val sport: Sport, val display: String, val norm: String, val tokens: List<String>) {
        var live = 0; var soon = 0; var later = 0
    }
    private class Ev(val e: SportsEvent, val norm: String, val tokens: List<String>)
    private class Index(val context: String, val revision: String, val builtAt: Long, val events: List<Ev>, val teams: List<Name>, val competitions: List<Name>, val identities: IdentityIndex, val ambiguous: Int, val unclassified: Int)

    private val lock = Any()
    private var cached: Index? = null
    @Volatile var builds = 0; private set

    fun invalidate() = synchronized(lock) { cached = null }

    /** Cold or warm, the index is made once per context and revision; later queries only compare strings. */
    private suspend fun index(): Pair<Index, Boolean> {
        val context = source.contextKey(); val now = source.now()
        synchronized(lock) { cached }?.let { if (it.context == context && now - it.builtAt < TTL_MS) return it to true }
        val load = source.load()
        currentCoroutineContext().ensureActive()
        synchronized(lock) { cached }?.let { old -> if (old.context == context && old.revision == load.revision) { val fresh = Index(old.context, old.revision, now, old.events, old.teams, old.competitions, old.identities, old.ambiguous, old.unclassified); synchronized(lock) { cached = fresh }; return fresh to true } }
        val built = withContext(Dispatchers.Default) { build(context, load, now) }
        synchronized(lock) { cached = built; builds++ }
        return built to false
    }

    private suspend fun build(context: String, load: SportsLoad, now: Long): Index {
        val identities = IdentityIndex.build(load.events)
        val teams = HashMap<String, Name>(); val comps = HashMap<String, Name>()
        val evs = ArrayList<Ev>(load.events.size)
        var unclassified = 0
        for (e in load.events) {
            currentCoroutineContext().ensureActive()
            if (e.endMs <= now) continue
            val state = e.state(now); val soon = state != SportsEventState.LIVE && e.startMs <= now + SOON_MS
            evs += Ev(e, SearchText.normalize(e.title + " " + (e.competition ?: "")), SearchText.tokens(e.title + " " + (e.competition ?: "")))
            if (e.participants.isEmpty() && e.competition == null) unclassified++
            identities.participants(e).forEachIndexed { i, k ->
                val n = teams.getOrPut(k) { val d = identities.displayName(k) ?: e.participants.getOrElse(i) { "" }; Name(k, e.sport, d, SearchText.normalize(d), SearchText.tokens(d)) }
                bump(n, state, soon)
            }
            identities.competition(e)?.let { k ->
                val n = comps.getOrPut(k) { val d = identities.displayName(k) ?: e.competition.orEmpty(); Name(k, e.sport, d, SearchText.normalize(d), SearchText.tokens(d)) }
                bump(n, state, soon)
            }
        }
        return Index(context, load.revision, now, evs, teams.values.toList(), comps.values.toList(), identities, identities.ambiguousCount, unclassified)
    }

    private fun bump(n: Name, state: SportsEventState, soon: Boolean) { if (state == SportsEventState.LIVE) n.live++ else if (soon) n.soon++ else n.later++ }

    /**
     * Matches for [typed]. Throws only for cancellation. A failure is reported as an exception to the caller, which keeps the library's own results untouched; this class never returns a partial list
     * that looks complete.
     */
    suspend fun search(typed: String): List<SearchItem> {
        val started = System.nanoTime()
        val text = SearchText.normalize(typed.take(MAX_QUERY))
        if (text.isEmpty()) return emptyList()
        val words = text.split(' ').filter { it.isNotEmpty() }.take(MAX_WORDS)
        try {
            val (ix, hit) = index()
            val follows = source.follows().withIndex(ix.identities)
            val now = source.now()
            val out = ArrayList<SearchItem>()
            // events
            val eventHits = ArrayList<Pair<Int, SearchItem>>()
            for (v in ix.events) {
                currentCoroutineContext().ensureActive()
                val base = match(text, words, v.norm, v.tokens) ?: continue
                val e = v.e; val state = e.state(now)
                val live = state == SportsEventState.LIVE; val soon = !live && e.startMs <= now + SOON_MS
                val score = base + (if (follows.matches(e)) FOLLOWED else 0) + (if (live) LIVE else if (soon) SOON else UPCOMING)
                eventHits += score to SearchItem("sports:e:" + e.id, SearchKind.SPORTS_EVENT, e.title, eventSubtitle(e, live, soon, now),
                    e.feeds.firstNotNullOfOrNull { it.logoUrl }, SearchTarget.OpenSports("event", e.id, e.sport.name, e.title, e.id), score)
            }
            out += eventHits.sortedWith(compareByDescending<Pair<Int, SearchItem>> { it.first }.thenBy { it.second.id }).take(MAX_EVENTS).map { it.second }
            out += names(text, words, ix.teams, follows, "t", SearchKind.SPORTS_TEAM, "team", MAX_NAMES)
            out += names(text, words, ix.competitions, follows, "c", SearchKind.SPORTS_COMPETITION, "competition", MAX_NAMES)
            // Recordings are found through their event: a stored request keeps no title, so it is listed when its event is in the guide and matches.
            val rec = RecordingIndex(source.recordings())
            val recHits = ArrayList<SearchItem>()
            for (v in ix.events) {
                currentCoroutineContext().ensureActive()
                val r = rec.forEvent(v.e) ?: continue
                val base = match(text, words, v.norm, v.tokens) ?: continue
                recHits += SearchItem("sports:r:" + r.id, SearchKind.SPORTS_RECORDING, v.e.title, recordingSubtitle(r), v.e.feeds.firstNotNullOfOrNull { it.logoUrl },
                    SearchTarget.OpenSports("recording", r.id, v.e.sport.name, v.e.title, v.e.id), base + (if (RecordingIndex.isOpen(r)) LIVE else 0))
            }
            out += recHits.sortedWith(compareByDescending<SearchItem> { it.score }.thenBy { it.id }).take(MAX_NAMES)
            diagnostics.record(DiscoveryReport(DiscoveryKind.SEARCH, if (out.isEmpty()) DiscoveryOutcome.EMPTY else DiscoveryOutcome.OK, out.size, (System.nanoTime() - started) / 1_000_000L, hit, ix.ambiguous, ix.unclassified))
            return out
        } catch (c: kotlinx.coroutines.CancellationException) {
            diagnostics.record(DiscoveryReport(DiscoveryKind.SEARCH, DiscoveryOutcome.CANCELLED, 0, (System.nanoTime() - started) / 1_000_000L, false)); throw c
        } catch (t: Exception) {
            diagnostics.record(DiscoveryReport(DiscoveryKind.SEARCH, DiscoveryOutcome.ERROR, 0, (System.nanoTime() - started) / 1_000_000L, false, failure = t.javaClass.simpleName)); throw t
        }
    }

    private suspend fun names(text: String, words: List<String>, list: List<Name>, follows: FollowSet, tag: String, kind: SearchKind, target: String, limit: Int): List<SearchItem> {
        val hits = ArrayList<SearchItem>()
        for (n in list) {
            currentCoroutineContext().ensureActive()
            val base = match(text, words, n.norm, n.tokens) ?: continue
            val followed = follows.isFollowing(if (target == "team") app.streamsetu.tv.sports.personal.FollowKind.PARTICIPANT else app.streamsetu.tv.sports.personal.FollowKind.COMPETITION, n.sport, n.key)
            val score = base + (if (followed) FOLLOWED else 0) + (if (n.live > 0) LIVE else if (n.soon > 0) SOON else UPCOMING)
            val sub = buildList { add(n.sport.title); if (n.live > 0) add("${n.live} live"); if (n.soon > 0) add("${n.soon} starting soon"); if (n.later > 0) add("${n.later} upcoming") }.joinToString(" · ")
            hits += SearchItem("sports:$tag:" + n.key, kind, n.display, sub, null, SearchTarget.OpenSports(target, n.key, n.sport.name, n.display, null), score)
        }
        return hits.sortedWith(compareByDescending<SearchItem> { it.score }.thenBy { it.title }.thenBy { it.id }).take(limit)
    }

    private fun eventSubtitle(e: SportsEvent, live: Boolean, soon: Boolean, now: Long): String {
        val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).also { it.timeZone = source.zone }
        val day = java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).also { it.timeZone = source.zone }
        val whenText = if (live) "Live now" else if (soon) "Starts in ${maxOf(1, (e.startMs - now + 59_999) / 60_000)} min" else day.format(java.util.Date(e.startMs)) + " " + clock.format(java.util.Date(e.startMs))
        return e.sport.title + (e.competition?.let { " · $it" } ?: "") + " · " + whenText
    }

    private fun recordingSubtitle(r: SportsRecordingEntity) = when (SportsRecordingStatus.valueOf(r.status)) {
        SportsRecordingStatus.SCHEDULED -> "Recording scheduled"; SportsRecordingStatus.RECORDING -> "Recording now"; SportsRecordingStatus.COMPLETED -> "Recorded"
        SportsRecordingStatus.FAILED -> "Recording failed"; SportsRecordingStatus.REVIEW_REQUIRED -> "Review recording"; SportsRecordingStatus.CANCELLED -> ""
    }

    companion object {
        const val EXACT = 3000; const val PREFIX = 2000; const val TOKENS = 1000
        const val FOLLOWED = 300; const val LIVE = 200; const val SOON = 100; const val UPCOMING = 0
        const val SOON_MS = 2 * 3_600_000L
        const val MAX_QUERY = 100; const val MAX_WORDS = 8; const val MAX_EVENTS = 8; const val MAX_NAMES = 5
        const val TTL_MS = 60_000L

        /** exact > prefix > every word starts a word of the name; null for no match. */
        fun match(text: String, words: List<String>, norm: String, tokens: List<String>): Int? = when {
            norm == text -> EXACT
            norm.startsWith(text) -> PREFIX
            words.all { w -> tokens.any { it.startsWith(w) } } -> TOKENS
            else -> null
        }
    }
}
