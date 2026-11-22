package app.streamsetu.core.data.smartmix

/** A shelf built but not yet shown. Pass it to [SmartMixService.commitRendered] after the first successful render. */
class BuiltShelf(val result: ShelfResult, val loadKey: String, internal val shown: List<Triple<String, Int?, String>>)

/**
 * Orchestration of one profile's shelves: seed state, repeat suppression, trending, fallbacks. No UI, no Android types.
 * Continue Watching is not part of this at all (it is protected and independent of every rule here).
 */
class SmartMixService(
    private val source: CandidateSource,
    private val store: SmartMixStore,
    private val trending: TrendingViewSource?,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Low-end devices / tests: smaller candidate pool. */
    private val poolCap: Int? = null,
) {
    companion object { const val MAX_ROWS = 48 }

    fun loadKey(dayKey: String, counter: Int) = "$dayKey|$counter"

    /** Reshuffle: bump the counter of the shelves on screen. Never starts a sync. */
    fun reshuffle(profileId: String, shelfIds: Collection<String>) {
        for (id in shelfIds) { val s = store.state(profileId, id); store.saveState(profileId, id, s.copy(refreshCounter = s.refreshCounter + 1)) }
    }

    /** Profile removed: drop its state. (Switching profile needs nothing: all state is keyed by profile.) */
    fun forgetProfile(profileId: String) = store.clearProfile(profileId)

    fun loadsAgo(profileId: String, shelfId: String, loadKey: String): Map<String, Int> {
        val st = store.state(profileId, shelfId)
        val eff = if (st.loadKey == loadKey) st.loadSeq else st.loadSeq + 1     // rows of the current seq are ignored: rebuilds are stable
        val m = HashMap<String, Int>()
        for (r in store.shown(profileId, shelfId)) { val a = eff - r.loadSeq; if (a >= 1) m.merge(r.identityKey, a, ::minOf) }
        return m
    }

    fun build(profileId: String, shelfId: String, dayKey: String): BuiltShelf {
        val spec = ShelfSpec.of(shelfId)
        val st = store.state(profileId, shelfId)
        val lk = loadKey(dayKey, st.refreshCounter)
        val signals = source.signals(profileId)
        val ctx = Context(profileId, dayKey, st.refreshCounter, preferredLang = signals.preferredLang, affinity = signals.affinity, poolCap = poolCap)
        val ago = loadsAgo(profileId, shelfId, lk)
        val wantsTrending = shelfId == ShelfSpec.TOP_WEEK || shelfId == ShelfSpec.TRENDING_LIBRARY || shelfId == ShelfSpec.HERO
        val view = if (wantsTrending && trending != null) trending.view(clock()) else TrendingView.OFF
        val request = PoolRequest(profileId, shelfId, dayKey, if (shelfId == ShelfSpec.FOR_YOU) signals.recentWatchedIdentityKeys.take(4) else emptyList(), spec.pool)
        var members = source.pool(request)
        var matched = emptyMap<String, Int>()
        val entries = view.entries
        if (entries != null) matched = TrendingMatcher.match(entries, source.matchCandidates(profileId, entries.flatMap { e -> listOfNotNull(TrendingMatcher.fold(e.title), e.original?.takeIf { it.isNotEmpty() }?.let(TrendingMatcher::fold)) }.toSet()))
        members = members.map { c -> c.copy(loadsAgo = ago[c.identityKey], trendingRank = matched[c.id]) }
        val prep = IdentityGrouping.prepare(members, signals.preferredLang)
        val ordered = shelfId == ShelfSpec.TOP_WEEK && entries != null &&
            prep.groups.count { !it.restricted && it.trendingRank != null } >= ShelfSpec.TRENDING_MIN_MATCHES
        val res = SmartMixEngine.buildShelf(prep, shelfId, ctx, ordered)
        val tmdb = if (wantsTrending) view.status else ""
        val withCaption = res.copy(diagnostics = res.diagnostics.copy(tmdb = tmdb))
        val byId = HashMap<String, Candidate>(); for (g in prep.groups) byId[g.id] = g
        val shown = withCaption.ids.mapNotNull { id -> byId[id]?.takeIf { !it.restricted }?.let { Triple(it.identityKey, it.year, it.id) } }
        return BuiltShelf(withCaption, lk, shown)
    }

    /** First successful render of a new load key: bump load_seq, record shown rows (never restricted ones), keep the newest rows. */
    fun commitRendered(profileId: String, built: BuiltShelf) {
        val shelfId = built.result.shelfId
        val st = store.state(profileId, shelfId)
        if (st.loadKey == built.loadKey) return
        val seq = st.loadSeq + 1
        val rows = (store.shown(profileId, shelfId) + built.shown.map { ShownRow(it.first, it.second, it.third, seq) })
            .sortedByDescending { it.loadSeq }.take(MAX_ROWS)
        store.replaceShown(profileId, shelfId, rows)
        store.saveState(profileId, shelfId, st.copy(loadKey = built.loadKey, loadSeq = seq))
    }

    /** All Home shelves; empty ones (and lang-pref without a preferred language) are left out. */
    fun buildHome(profileId: String, dayKey: String): List<BuiltShelf> =
        ShelfSpec.GLOBAL.map { build(profileId, it, dayKey) }.filter { !it.result.hidden && it.result.ids.isNotEmpty() }
}
