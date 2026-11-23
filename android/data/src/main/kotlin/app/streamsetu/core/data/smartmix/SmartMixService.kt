package app.streamsetu.core.data.smartmix

/** A shelf built but not yet shown. Pass it to [SmartMixService.commitRendered] after the first successful render. */
class BuiltShelf(val result: ShelfResult, val loadKey: String, internal val shown: List<Triple<String, Int?, String>>, /** The picks with what composition needs (Home v2). */ val picks: List<HomePick> = emptyList())

/**
 * Orchestration of one profile's shelves: seed state, repeat suppression, trending, fallbacks. No UI, no Android types.
 * Continue Watching is not part of this at all (it is protected and independent of every rule here).
 */
class SmartMixService(
    private val source: CandidateSource,
    private val store: SmartMixStore,
    private val trending: TrendingViewSource?,
    /** The saved TMDB lists of the genre shelves and of the all-time view; null = none (the local ranking stands). */
    private val lists: RankedLists? = null,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Low-end devices / tests: smaller candidate pool. */
    private val poolCap: Int? = null,
) {
    companion object { const val MAX_ROWS = 48 }

    fun loadKey(dayKey: String, counter: Int) = "$dayKey|$counter"

    /** Reshuffle: bump the counter of the shelves on screen. Never starts a sync. */
    fun reshuffle(profileId: String, shelfIds: Collection<String>) {
        for (id in shelfIds + listOf("genres:auto", "moods:auto", ShelfSpec.COLLECTIONS)) { val s = store.state(profileId, id); store.saveState(profileId, id, s.copy(refreshCounter = s.refreshCounter + 1)) }
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

    fun build(profileId: String, shelfId: String, dayKey: String, shelfView: ShelfView = ShelfView.WEEKLY, kids: Boolean = false, oversample: Int = 0, libraryTotal: Int = 0): BuiltShelf {
        val spec = ShelfSpec.of(shelfId, shelfView, kids)
        val isGenre = spec.genre != null
        val st = store.state(profileId, shelfId)
        val lk = loadKey(dayKey, st.refreshCounter)
        val signals = source.signals(profileId)
        val ctx = Context(profileId, dayKey, st.refreshCounter, preferredLang = signals.preferredLang, affinity = signals.affinity, poolCap = poolCap, oversample = oversample, kids = kids, libraryTotal = libraryTotal)
        val ago = loadsAgo(profileId, shelfId, lk)
        val wantsTrending = shelfId == ShelfSpec.TOP_WEEK || shelfId == ShelfSpec.TRENDING_LIBRARY || shelfId == ShelfSpec.HERO || isGenre
        val weekly = if (wantsTrending && trending != null) trending.view(clock()) else TrendingView.OFF
        // Which list orders the shelf: its own (genres), else the whole-library list of the same view (this week's trending, or the all-time top).
        val general: TrendingView = if (shelfView == ShelfView.ALL_TIME && (shelfId == ShelfSpec.TRENDING_LIBRARY || isGenre)) lists?.entries("top", clock())?.let { TrendingView("active", it) } ?: TrendingView.OFF else weekly
        val view = if (!wantsTrending) TrendingView.OFF else if (shelfId == ShelfSpec.TRENDING_LIBRARY) general else if (isGenre) general else weekly
        val ownEntries = if (isGenre) lists?.entries(GenreShelves.listNames(shelfId, shelfView).first, clock()) else null
        val request = PoolRequest(profileId, shelfId, dayKey, if (shelfId == ShelfSpec.FOR_YOU) signals.recentWatchedIdentityKeys.take(4) else emptyList(), spec.pool)
        var members = source.pool(request)
        var matched = emptyMap<String, Int>()
        var entries = view.entries
        fun matchOf(list: List<TrendingEntry>) = TrendingMatcher.match(list, source.matchCandidates(profileId, list.flatMap { e -> listOfNotNull(TrendingMatcher.fold(e.title), e.original?.takeIf { it.isNotEmpty() }?.let(TrendingMatcher::fold)) }.toSet()))
        if (ownEntries != null) { val m = matchOf(ownEntries); if (m.isNotEmpty()) { matched = m; entries = ownEntries } }
        if (matched.isEmpty() && entries != null) matched = matchOf(entries)
        members = members.map { c -> c.copy(loadsAgo = ago[c.identityKey], trendingRank = matched[c.id]) }
        val prep = IdentityGrouping.prepare(members, signals.preferredLang)
        val ordered = shelfId == ShelfSpec.TOP_WEEK && entries != null &&
            prep.groups.count { !it.restricted && it.trendingRank != null } >= ShelfSpec.TRENDING_MIN_MATCHES
        val res = SmartMixEngine.buildShelf(prep, shelfId, ctx, ordered, shelfView)
        val tmdb = if (wantsTrending) (if (entries != null && isGenre) "active" else view.status) else ""
        val withCaption = res.copy(diagnostics = res.diagnostics.copy(tmdb = tmdb))
        val byId = HashMap<String, Candidate>(); for (g in prep.groups) byId[g.id] = g
        // Repeat suppression records only the first `size` picks, never the oversampled extras.
        val shown = withCaption.ids.take(spec.size).mapNotNull { id -> byId[id]?.takeIf { !it.restricted }?.let { Triple(it.identityKey, it.year, it.id) } }
        val picks = withCaption.ids.mapNotNull { id -> byId[id]?.let { c -> pickOf(c) } }
        return BuiltShelf(withCaption, lk, shown, picks)
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

    /** What the genre shelves of today are: the shelves that have 8 titles or more, and the "Browse by genre" row. [viewOf] is the remembered view of each shelf. */
    class GenreHome(val shelves: List<BuiltShelf>, val browse: List<Pair<GenreDef, Int>>)

    fun buildGenres(profileId: String, dayKey: String, kids: Boolean, viewOf: (String) -> ShelfView = { ShelfView.WEEKLY }): GenreHome {
        val counts = source.genreCounts(profileId)
        val counter = store.state(profileId, "genres:auto").refreshCounter
        val chosen = GenreShelves.select(counts, profileId, dayKey, counter, kids, source.affinityGenreKeys(profileId))
        val built = chosen.map { build(profileId, GenreShelves.PREFIX + it, dayKey, viewOf(GenreShelves.PREFIX + it)) }.filter { !it.result.hidden && it.result.ids.isNotEmpty() }
        return GenreHome(built, GenreShelves.browse(counts, kids))
    }

    private fun pickOf(c: Candidate) = HomePick(c.id, c.kind == Kind.SERIES, c.year, c.primaryGenre ?: c.genres.firstOrNull(), c.genres, c.lang, c.franchiseKey)

    /** One row of Home v2 as the screen needs it: the shelf id, its titles (each once on the screen), the view it shows (ranked rows) and whether that view was chosen for the person ("Quiet week"). */
    class HomeRowBuilt(val id: String, val ids: List<String>, val view: ShelfView?, val quietWeek: Boolean, val ordered: Boolean, val built: BuiltShelf?)
    class HomeV2(val rows: List<HomeRowBuilt>, val browse: List<Pair<GenreDef, Int>>, val built: List<BuiltShelf>, /** Collection tile by the id of its lead title. */ val collections: Map<String, HomeCollections.Group>)

    private fun isOrdered(b: BuiltShelf) = b.result.diagnostics.caption == "trendingTMDB"

    /** The view a ranked row opens on (section 10.6): the person's choice, else this week unless the week was quiet and the all-time list orders the row. */
    private fun buildRanked(profileId: String, shelfId: String, dayKey: String, chosen: ShelfView?, kids: Boolean, oversample: Int, total: Int): Triple<BuiltShelf, ShelfView, Boolean> {
        if (chosen != null) return Triple(build(profileId, shelfId, dayKey, chosen, kids, oversample, total), chosen, false)
        val weekly = build(profileId, shelfId, dayKey, ShelfView.WEEKLY, kids, oversample, total)
        if (isOrdered(weekly)) return Triple(weekly, ShelfView.WEEKLY, false)
        val all = build(profileId, shelfId, dayKey, ShelfView.ALL_TIME, kids, oversample, total)
        val d = HomeModeDefault.decide(null, false, isOrdered(all))
        return if (d.auto) Triple(all, ShelfView.ALL_TIME, true) else Triple(weekly, ShelfView.WEEKLY, false)
    }

    /**
     * Home v2 (docs/SMART-MIX.md section 10): every engine row built with oversampling, the moods limited, composed so that a title appears once, ordered by the day's context.
     * [chosenOf] is the person's stored view of a ranked row (null = none). Nothing here starts a sync or touches Continue Watching.
     */
    fun buildHomeV2(profileId: String, dayKey: String, kids: Boolean, day: HomeDayContext, chosenOf: (String) -> ShelfView? = { null }, oversample: Int = 10): HomeV2 {
        val total = source.showableTotal(profileId)
        val built = ArrayList<BuiltShelf>(); val views = HashMap<String, Pair<ShelfView, Boolean>>()
        fun add(b: BuiltShelf) = built.add(b)
        val counts = source.genreCounts(profileId)
        val genreCounter = store.state(profileId, "genres:auto").refreshCounter
        val chosenGenres = GenreShelves.select(counts, profileId, dayKey, genreCounter, kids, source.affinityGenreKeys(profileId))
        for (g in chosenGenres) {
            val id = GenreShelves.PREFIX + g
            val (b, v, quiet) = buildRanked(profileId, id, dayKey, chosenOf(id), kids, oversample, total)
            views[id] = v to quiet; add(b)
        }
        val (tb, tv, tq) = buildRanked(profileId, ShelfSpec.TRENDING_LIBRARY, dayKey, chosenOf(ShelfSpec.TRENDING_LIBRARY), kids, oversample, total)
        views[ShelfSpec.TRENDING_LIBRARY] = tv to tq; add(tb)
        for (id in listOf(ShelfSpec.TOP_WEEK, ShelfSpec.FOR_YOU, ShelfSpec.REDISCOVER, ShelfSpec.LANG_PREF) + ShelfSpec.CONTEXT) add(build(profileId, id, dayKey, ShelfView.WEEKLY, kids, oversample, total))
        for (m in HomeMoods.allowed(kids)) add(build(profileId, m.shelfId, dayKey, ShelfView.WEEKLY, kids, oversample, total))
        // Collections: franchises of 3 titles or more, shown as tiles led by their best rated title.
        val signals = source.signals(profileId)
        val colCounter = store.state(profileId, ShelfSpec.COLLECTIONS).refreshCounter
        val groups = HomeCollections.groups(IdentityGrouping.prepare(source.pool(PoolRequest(profileId, ShelfSpec.COLLECTIONS, dayKey, emptyList(), 2000)), signals.preferredLang).groups)
        val tiles = HomeCollections.select(groups, profileId, dayKey, colCounter)
        val results = built.map { b -> HomeRowResult(b.result.shelfId, b.picks, isOrdered(b) && b.result.shelfId != ShelfSpec.FOR_YOU, b.result.hidden) } +
            HomeRowResult(ShelfSpec.COLLECTIONS, tiles.map { HomePick(it.lead.id, it.lead.kind == Kind.SERIES, it.lead.year, it.lead.primaryGenre, it.lead.genres, it.lead.lang, it.key) }, false, tiles.isEmpty())
        val moodCounter = store.state(profileId, "moods:auto").refreshCounter
        val composed = HomeCompose.compose(results, HomeAffinity(source.affinityGenreKeys(profileId), signals.affinity.topLangs), day, kids) { avail -> HomeMoods.limit(avail, profileId, dayKey, moodCounter, kids) }
        val byId = built.associateBy { it.result.shelfId }
        val rows = composed.map { r -> val v = views[r.row]; HomeRowBuilt(r.row, r.ids, v?.first, v?.second == true, byId[r.row]?.let { b -> isOrdered(b) } == true, byId[r.row]) }
        return HomeV2(rows, GenreShelves.browse(counts, kids), built.filter { b -> rows.any { it.id == b.result.shelfId } }, tiles.associateBy { it.lead.id })
    }

    /** All Home shelves; empty ones (and lang-pref without a preferred language) are left out. */
    fun buildHome(profileId: String, dayKey: String): List<BuiltShelf> =
        ShelfSpec.GLOBAL.map { build(profileId, it, dayKey) }.filter { !it.result.hidden && it.result.ids.isNotEmpty() }
}
