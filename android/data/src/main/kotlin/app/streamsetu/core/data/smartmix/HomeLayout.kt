package app.streamsetu.core.data.smartmix

/*
 * Home v2 (docs/SMART-MIX.md sections 10 to 12): row names, moods, franchise keys, context, placement by weekday and hour, one-title-per-screen composition, collections,
 * the default view of a ranked row. Pure, integers only, strings by UTF-8 bytes. The contract is smartmix/fixtures/home-layout.json (written by smartmix/tools/make_home_fixtures.py).
 */

/** Spacing of Home in dp (section 11): the same numbers as the Apple apps. */
object HomeLayoutTokens {
    const val ROW_GAP = 24
    const val HEADER_TO_TILES = 12
    const val TILE_GAP = 12
    const val SUBTITLE_MIN_HEIGHT = 30
    const val SKELETON_ROWS = 3
    const val MIN_TARGET = 48
}

/** Row names (English text is the key; Hindi and Telugu are in the i18n assets). */
object HomeRowNames {
    const val CONTINUE = "Pick Up Where You Left Off"
    const val CONTINUE_SUBTITLE = "Movies and episodes you started"
    const val TOP_WEEK = "This Week's Top Picks"
    const val TOP_WEEK_ORDERED = "Popular right now"
    const val TOP_WEEK_LOCAL = "Most watched and best rated here"
    const val TRENDING = "Popular in Your Library"
    const val FOR_YOU = "Picked for You"
    const val BECAUSE_YOU_WATCHED = "Because You Watched"
    const val REDISCOVER = "Hidden Gems"
    const val FRESH = "Fresh Additions"
    const val MOVIE_NIGHT = "Movie Night"
    const val BINGE = "Binge-Worthy Series"
    const val COLLECTIONS = "Collections"
    const val BROWSE_GENRE = "Browse by Genre"
    const val QUIET_WEEK = "Quiet week: all time"
    val ROWS = listOf(CONTINUE, TOP_WEEK, TRENDING, FOR_YOU, REDISCOVER, FRESH, MOVIE_NIGHT, BINGE, COLLECTIONS, BROWSE_GENRE, "With the Kids", "Edge of Your Seat", "Feel-Good Picks")

    /** Friendly titles of the genre rows by genre key (the "Top <Name>" titles of the table stay as data keys). */
    val GENRES: Map<String, String> = linkedMapOf(
        "action" to "Action Packed", "comedy" to "Laugh Out Loud", "drama" to "Drama Worth Your Time", "thriller" to "Thrillers Worth Watching", "scifi" to "Sci-Fi Picks",
        "horror" to "Horror After Dark", "romance" to "Love Stories", "crime" to "Crime Stories", "animation" to "Animated Favourites", "documentary" to "Real-World Docs",
        "family" to "Family Time", "fantasy" to "Fantasy Worlds", "mystery" to "Mysteries to Solve", "adventure" to "Adventure Awaits", "war" to "War Stories", "western" to "Westerns",
        "history" to "History Comes Alive", "music" to "Music and Musicals", "biography" to "True Life Stories", "kids" to "Kids' Corner", "anime" to "Anime Picks", "reality" to "Reality Favourites",
    )

    /** The title of a shelf; [language] is the preferred language's name for "<Language> Picks". Null for a shelf that has no row on Home (hero). */
    fun title(shelfId: String, language: String? = null): String? = when {
        shelfId.startsWith(GenreShelves.PREFIX) -> GENRES[shelfId.removePrefix(GenreShelves.PREFIX)] ?: GenreTable.ofShelf(shelfId)?.title
        shelfId.startsWith(HomeMoods.PREFIX) -> HomeMoods.of(shelfId)?.title
        else -> when (shelfId) {
            ShelfSpec.TOP_WEEK -> TOP_WEEK
            ShelfSpec.TRENDING_LIBRARY -> TRENDING
            ShelfSpec.FOR_YOU -> FOR_YOU
            ShelfSpec.REDISCOVER -> REDISCOVER
            ShelfSpec.LANG_PREF -> if (language.isNullOrBlank()) null else "${language.replaceFirstChar { it.uppercase() }} Picks"
            ShelfSpec.FRESH -> FRESH
            ShelfSpec.MOVIE_NIGHT -> MOVIE_NIGHT
            ShelfSpec.BINGE -> BINGE
            ShelfSpec.COLLECTIONS -> COLLECTIONS
            else -> null
        }
    }

    /** The line under a row's title for rows that are not switchable ranked rows; null when none. */
    fun subtitle(shelfId: String, tmdbOrdered: Boolean): String? = when (shelfId) {
        ShelfSpec.TOP_WEEK -> if (tmdbOrdered) TOP_WEEK_ORDERED else TOP_WEEK_LOCAL
        ShelfSpec.FOR_YOU -> "Based on what you watch most"
        ShelfSpec.REDISCOVER -> "Well rated and waiting for you"
        ShelfSpec.FRESH -> "Added in the last two weeks"
        ShelfSpec.MOVIE_NIGHT -> "Well-rated films for tonight"
        ShelfSpec.BINGE -> "Well-rated shows to settle into"
        ShelfSpec.COLLECTIONS -> "Film series in your library"
        "mood:withKids" -> "Safe, bright and made to share"
        "mood:edge" -> "Tense stories you cannot pause"
        "mood:feelGood" -> "Light, warm and easy to enjoy"
        else -> null
    }
}

/** Moods: a union of genre keys (section 10.2). */
data class MoodDef(val key: String, val title: String, val genreKeys: List<String>, val kidsOK: Boolean) { val shelfId: String get() = HomeMoods.PREFIX + key }

object HomeMoods {
    const val PREFIX = "mood:"
    const val MAX_SHOWN = 2
    val all: List<MoodDef> = listOf(
        MoodDef("withKids", "With the Kids", listOf("family", "animation", "kids", "adventure"), true),
        MoodDef("edge", "Edge of Your Seat", listOf("thriller", "crime", "mystery"), false),
        MoodDef("feelGood", "Feel-Good Picks", listOf("comedy", "romance", "family", "music"), true),
    )
    fun of(shelfId: String): MoodDef? = if (shelfId.startsWith(PREFIX)) all.firstOrNull { it.key == shelfId.substring(PREFIX.length) } else null

    /** The moods a profile may have: all of them, or only the kid-safe ones (and only kid-safe genres inside them) for a Kids profile. */
    fun allowed(kids: Boolean): List<MoodDef> = if (kids) all.filter { it.kidsOK } else all

    /** The genre keys a mood draws from for this profile. */
    fun genreKeys(m: MoodDef, kids: Boolean): List<String> = if (kids) m.genreKeys.filter { GenreTable.of(it)?.kids == true } else m.genreKeys

    /** A mood needs at least max(8, total * 15 / 1000) matching showable titles; [total] = showable titles in the pool (1.5% of the library). */
    fun floor(total: Int): Int = maxOf(8, (total.toLong() * 15 / 1000).toInt())

    /** Section 10.4 step 1: at most 2 mood rows. Kids: table order; others: a rotation by uniform(n) of SplitMix64(seed(profile, "moods:auto", day, counter)). */
    fun limit(available: List<String>, profileId: String, dayKey: String, refreshCounter: Int, kids: Boolean): List<String> {
        if (available.size <= MAX_SHOWN) return available
        if (kids) return available.take(MAX_SHOWN)
        val off = SmartMixSeed.rng(profileId, "moods:auto", dayKey, refreshCounter).uniform(available.size.toULong()).toInt()
        return (available.drop(off) + available.take(off)).take(MAX_SHOWN)
    }
}

/** Franchise key of an identity key (section 10.3): the first two words when the key is a series of instalments. */
object HomeFranchise {
    private val SMALL = ("its a an the i my me in on of to is are one all no you we our your this that with from for not too his her how what when who love man day night life").split(' ').toSet()
    private val ROMAN = setOf("ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x")
    private val MARK = setOf("part", "chapter", "vol", "volume", "episode")
    private val FUNCTION = setOf("of", "the", "in", "on", "to", "a", "an", "for", "with", "and", "is", "at", "by")

    private fun digits(w: String) = w.isNotEmpty() && w.all { it in '0'..'9' }
    private fun isMarker(w: String) = (w.length <= 2 && digits(w)) || w in ROMAN || w in MARK

    fun key(identityKey: String): String? {
        val w = identityKey.split(' ').toMutableList()
        while (w.size > 1 && isMarker(w.last())) w.removeAt(w.size - 1)
        if (w.size < 2) return null
        val a = w[0]; val b = w[1]
        if (b in FUNCTION) return null
        if (digits(a) && digits(b)) return null
        if (!listOf(a, b).any { it.length >= 4 && it !in SMALL }) return null
        return "$a $b"
    }
}

/** One title as composition sees it. */
data class HomePick(val id: String, val series: Boolean = false, val year: Int? = null, val genre: String? = null, val genres: List<String> = emptyList(), val lang: String? = null, val franchise: String? = null)

/** What the engine built for one row (oversampled). [ordered] = TMDB order (kept as it is). */
data class HomeRowResult(val id: String, val picks: List<HomePick>, val ordered: Boolean = false, val hidden: Boolean = false)

data class HomeAffinity(val genreKeys: List<String> = emptyList(), val topLangs: List<String> = emptyList())

data class HomeRow(val row: String, val ids: List<String>)

/** Time of day and week from the device clock (section 10.5). [weekday] 1 Monday ... 7 Sunday. */
data class HomeDayContext(val weekday: Int, val hour: Int) {
    val movieNight: Boolean get() = ((weekday == 5 || weekday == 6) && hour >= 17) || ((weekday == 6 || weekday == 7) && hour < 4)
    val weekend: Boolean get() = weekday >= 6
    val morning: Boolean get() = hour in 5..10

    companion object {
        fun now(clock: java.time.LocalDateTime = java.time.LocalDateTime.now()) = HomeDayContext(clock.dayOfWeek.value, clock.hour)
    }
}

object HomePlacement {
    private val NORMAL = listOf("top-week", "for-you", "movie-night", "G", "trending", "M", "G", "lang-pref", "binge", "collections", "G", "rediscover", "M", "G", "fresh", "G", "G")
    private val MORNING = listOf("top-week", "fresh", "for-you", "G", "trending", "M", "G", "lang-pref", "collections", "G", "movie-night", "binge", "M", "rediscover", "G", "G")
    private val KIDS = listOf("M", "top-week", "G", "for-you", "G", "fresh", "collections", "G", "M", "rediscover", "lang-pref", "G", "trending", "G")
    const val MAX_ROWS = 12
    const val THIN_PAGE = 6

    fun kind(id: String): String = when {
        id == "top-week" || id == "trending" -> "ranking"
        id == "for-you" || id == "rediscover" || id == "lang-pref" -> "personal"
        id == "fresh" || id == "movie-night" || id == "binge" -> "context"
        id == "collections" -> "collection"
        id.startsWith(HomeMoods.PREFIX) -> "mood"
        else -> "genre"
    }

    /** The order of rows. [present] uses the template names ("trending" for Trending in Your Library); [genres] and [moods] are shelf ids in their chosen order. */
    fun layout(present: Set<String>, genres: List<String>, moods: List<String>, ctx: HomeDayContext, kids: Boolean): List<String> {
        val g = ArrayDeque(genres); val m = ArrayDeque(moods)
        val tokens = if (kids) KIDS else if (ctx.morning) MORNING else NORMAL
        val queue = ArrayList<String>()
        for (t in tokens) when (t) {
            "G" -> g.removeFirstOrNull()?.let { queue.add(it) }
            "M" -> m.removeFirstOrNull()?.let { queue.add(it) }
            "movie-night" -> if (t in present && ctx.movieNight) queue.add(t)
            "binge" -> if (t in present && ctx.weekend) queue.add(t)
            else -> if (t in present) queue.add(t)
        }
        queue.addAll(g); queue.addAll(m)
        val out = ArrayList<String>(); val dropped = ArrayDeque<String>()
        while (queue.isNotEmpty() && out.size < MAX_ROWS) {
            val last = out.lastOrNull()?.let(::kind)
            val pick = (0 until minOf(3, queue.size)).firstOrNull { kind(queue[it]) != last }
            if (pick == null) dropped.add(queue.removeAt(0)) else out.add(queue.removeAt(pick))
        }
        while (out.size < THIN_PAGE && dropped.isNotEmpty()) out.add(dropped.removeFirst())
        return out
    }
}

/** One title once per screen: exclusion by earlier rows, MMR re-rank, exploration slots (section 10.4). */
object HomeCompose {
    const val ROW_SIZE = 14
    fun minimum(id: String) = if (id == ShelfSpec.TRENDING_LIBRARY) 3 else if (id.startsWith(GenreShelves.PREFIX)) 8 else 6

    private fun decade(y: Int) = Math.floorDiv(y, 10)

    /** Greedy MMR over the first 8 unchosen titles; relevance 1000 - 30 * drawPosition. */
    fun rerank(picks: List<HomePick>, n: Int): List<HomePick> {
        val rest = picks.withIndex().toMutableList()
        val out = ArrayList<HomePick>()
        while (out.size < n && rest.isNotEmpty()) {
            var best = 0; var bestScore = Int.MIN_VALUE; var have = false
            for (i in 0 until minOf(rest.size, 8)) {
                val (pos, c) = rest[i]
                var s = 1000 - 30 * pos
                val recent = out.takeLast(3).reversed()
                for ((back, o) in recent.withIndex()) {
                    if (c.franchise != null && c.franchise == o.franchise) s -= 300
                    if (c.year != null && o.year != null && decade(c.year) == decade(o.year)) s -= 60
                    if (back < 2) {
                        if (c.genre != null && c.genre == o.genre) s -= 80
                        if (c.lang != null && c.lang == o.lang && c.series == o.series) s -= 40
                    }
                }
                if (!have || s > bestScore) { best = i; bestScore = s; have = true }
            }
            out.add(rest.removeAt(best).value)
        }
        return out
    }

    private fun isExploration(p: HomePick, aff: HomeAffinity): Boolean {
        val keys = GenreShelves.keysFor(p.genres, p.series)
        if (keys.isNotEmpty() && keys.any { it in aff.genreKeys }) return false
        if (p.lang != null && aff.topLangs.firstOrNull() == p.lang) return false
        return true
    }

    /** Positions 6 and 12 (index 5, 11): a title inside the person's taste is replaced by the first leftover title outside it. Nothing happens without history. */
    fun explore(main: List<HomePick>, left: List<HomePick>, aff: HomeAffinity): List<HomePick> {
        if (aff.genreKeys.isEmpty() && aff.topLangs.isEmpty()) return main
        val out = main.toMutableList()
        val pool = ArrayDeque(left.filter { isExploration(it, aff) })
        var slot = 5
        while (slot < out.size) {
            if (!isExploration(out[slot], aff) && pool.isNotEmpty()) out[slot] = pool.removeFirst()
            slot += 6
        }
        return out
    }

    /** Rows in layout order, each title once. The result lists only the rows that survived, in their final layout order. */
    fun compose(results: List<HomeRowResult>, aff: HomeAffinity, ctx: HomeDayContext, kids: Boolean, moodOrder: ((List<String>) -> List<String>)? = null): List<HomeRow> {
        fun shown(r: HomeRowResult) = !r.hidden && r.picks.isNotEmpty()
        val by = results.associateBy { it.id }
        val genreIds = results.filter { it.id.startsWith(GenreShelves.PREFIX) && shown(it) }.map { it.id }
        val moodAll = results.filter { it.id.startsWith(HomeMoods.PREFIX) && shown(it) }.map { it.id }
        val moodIds = moodOrder?.invoke(moodAll) ?: moodAll
        fun present(ids: Collection<String>): Set<String> {
            val s = HashSet<String>()
            for (r in results) {
                val i = r.id
                if (shown(r) && i in ids && !i.startsWith(GenreShelves.PREFIX) && !i.startsWith(HomeMoods.PREFIX) && i != ShelfSpec.HERO) s.add(if (i == ShelfSpec.TRENDING_LIBRARY) "trending" else i)
            }
            return s
        }
        fun rid(i: String) = if (i == "trending") ShelfSpec.TRENDING_LIBRARY else i
        val first = HomePlacement.layout(present(by.keys), genreIds, moodIds, ctx, kids).map(::rid)
        val used = HashSet<String>(); val rows = HashMap<String, List<String>>()
        for (i in first) {
            val r = by[i] ?: continue
            if (i == ShelfSpec.COLLECTIONS) { rows[i] = r.picks.map { it.id }; continue }
            val free = r.picks.filter { it.id !in used }
            val picks: List<HomePick>
            if (r.ordered) picks = free.take(ROW_SIZE)
            else {
                var p = rerank(free, ROW_SIZE)
                if (i == ShelfSpec.FOR_YOU) { val chosen = p.map { it.id }.toSet(); p = explore(p, free.filter { it.id !in chosen }, aff) }
                picks = p
            }
            if (picks.size < minimum(i)) continue
            used.addAll(picks.map { it.id })
            rows[i] = picks.map { it.id }
        }
        val surv = rows.keys
        val order = HomePlacement.layout(present(surv), genreIds.filter { it in surv }, moodIds.filter { it in surv }, ctx, kids).map(::rid)
        return order.filter { it in rows }.map { HomeRow(it, rows.getValue(it)) }
    }

    /** Single-row rebuild (a view switch): titles on the other rows are skipped when at least the minimum remain, else the plain row. */
    fun single(id: String, picks: List<HomePick>, usedElsewhere: Set<String>, ordered: Boolean): List<HomePick> {
        val free = picks.filter { it.id !in usedElsewhere }
        val base = if (free.size >= minimum(id)) free else picks
        return if (ordered) base.take(ROW_SIZE) else rerank(base, ROW_SIZE)
    }
}

/** The view a ranked row opens on (section 10.6). */
object HomeModeDefault {
    data class Decision(val mode: ShelfView, val auto: Boolean)

    fun decide(chosen: ShelfView?, weeklyOrdered: Boolean, allTimeOrdered: Boolean): Decision =
        if (chosen != null) Decision(chosen, false)
        else if (!weeklyOrdered && allTimeOrdered) Decision(ShelfView.ALL_TIME, true)
        else Decision(ShelfView.WEEKLY, false)
}

/** Collections (section 10.3): franchises with at least 3 titles. */
object HomeCollections {
    const val MIN_TITLES = 3
    const val MIN_FRANCHISES = 3
    const val DRAWN = 24
    const val SHOWN = 12

    /** One franchise: members in release order, the lead title (best rated), the name and the strength. */
    data class Group(val key: String, val name: String, val lead: Candidate, val members: List<Candidate>, val strength: Int)

    private val TRAILING = setOf("of", "the", "in", "on", "to", "a", "an", "for", "with", "and", "is", "at", "by", "part", "chapter", "vol", "volume", "episode", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x")

    /** The common leading words of the members' identity keys minus trailing small words and numbers, else the key title-cased. */
    fun nameOf(key: String, members: List<Candidate>): String {
        val lists = members.map { it.identityKey.split(' ') }
        var n = lists.minOf { it.size }
        var prefix = 0
        while (prefix < n && lists.all { it[prefix] == lists[0][prefix] }) prefix++
        n = prefix
        val words = lists[0].take(n).toMutableList()
        while (words.isNotEmpty() && (words.last() in TRAILING || words.last().all { it in '0'..'9' })) words.removeAt(words.size - 1)
        val use = if (words.size >= 2) words else key.split(' ')
        return use.joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }
    }

    /** Groups of >= 3 distinct showable titles (not restricted, not dismissed, not CAM-only, with a poster), strongest first; [groups] are the representatives of [IdentityGrouping.prepare]. */
    fun groups(groups: List<Candidate>): List<Group> {
        val by = LinkedHashMap<String, ArrayList<Candidate>>()
        for (c in groups) {
            if (c.restricted || c.dismissed || c.camOnly || !c.hasPoster) continue
            val k = HomeFranchise.key(c.identityKey) ?: continue
            by.getOrPut(k) { ArrayList() }.add(c)
        }
        val out = ArrayList<Group>()
        for ((k, list) in by) {
            if (list.size < MIN_TITLES) continue
            val rated = list.map { Features.parseTenths(it.ratingText) }
            val known = rated.filterNotNull()
            val avg = if (known.isEmpty()) 60 else known.sum() / known.size
            val members = list.sortedWith { a, b -> compareValuesBy(a, b, { it.year ?: Int.MAX_VALUE }) .let { r -> if (r != 0) r else SmartMixEngine.compareUtf8(a.id, b.id) } }
            val lead = list.sortedWith { a, b ->
                val ra = Features.parseTenths(a.ratingText) ?: 0; val rb = Features.parseTenths(b.ratingText) ?: 0
                if (ra != rb) rb.compareTo(ra) else SmartMixEngine.compareUtf8(a.id, b.id)
            }.first()
            out.add(Group(k, nameOf(k, list), lead, members, list.size * 100 + avg))
        }
        return out.sortedWith { a, b -> if (a.strength != b.strength) b.strength.compareTo(a.strength) else SmartMixEngine.compareUtf8(a.key, b.key) }
    }

    /** The tiles to show: the first 24 each get one next() of SplitMix64(seed(profile, "collections", day, counter)), ordered by (position / 4, drawn value, key bytes); the first 12 shown; none with fewer than 3 franchises. */
    fun select(all: List<Group>, profileId: String, dayKey: String, refreshCounter: Int): List<Group> {
        if (all.size < MIN_FRANCHISES) return emptyList()
        val rng = SmartMixSeed.rng(profileId, "collections", dayKey, refreshCounter)
        val top = all.take(DRAWN).withIndex().map { Triple(it.index, rng.next(), it.value) }
        return top.sortedWith { a, b ->
            val pa = a.first / 4; val pb = b.first / 4
            if (pa != pb) pa.compareTo(pb) else if (a.second != b.second) a.second.compareTo(b.second) else SmartMixEngine.compareUtf8(a.third.key, b.third.key)
        }.take(SHOWN).map { it.third }
    }
}

/**
 * "Because You Watched <title>" (docs/SMART-MIX.md 10.1): used only when the similarity code of the app (franchise, director, genre, cast, story) links one seed to at least
 * [MIN_LINKED] titles of the row; those titles lead the row. Otherwise the row is "Picked for You". The seeds are the last 3 movies and 2 series watched, newest first.
 */
object HomeBecause {
    const val MIN_LINKED = 3
    const val SEED_MOVIES = 3
    const val SEED_SERIES = 2
    private val REAL = setOf("Same franchise", "Same director", "Same genre", "Shared cast", "Similar story")

    /** The seed that names the row and the ids of the row's titles linked to it, strongest first. */
    data class Link(val seedTitle: String, val linkedIds: List<String>)

    /** The first seed (newest first) with the most links; null when none reaches [MIN_LINKED]. A seed is never linked to itself, and only real reasons count (not the same folder, language, year or rating). */
    fun choose(seeds: List<app.streamsetu.core.data.repo.Similarity.Item>, row: List<app.streamsetu.core.data.repo.Similarity.Item>): Link? {
        var best: Link? = null
        for (seed in seeds) {
            val rowIds = row.map { it.id }.toSet()
            val linked = app.streamsetu.core.data.repo.Similarity.rank(seed, null, row.filter { it.id != seed.id }, limit = row.size.coerceAtLeast(1))
                .filter { it.reason in REAL && it.id in rowIds }.map { it.id }
            if (linked.size >= MIN_LINKED && linked.size > (best?.linkedIds?.size ?: 0)) best = Link(seed.title, linked)
        }
        return best
    }

    /** The row's ids with the linked ones first (in link order), the others after them in their own order. */
    fun lead(ids: List<String>, link: Link?): List<String> = if (link == null) ids else link.linkedIds.filter { it in ids } + ids.filter { it !in link.linkedIds }

    /** The heading in English; the app translates "Because You Watched" and appends the seed's own title. */
    fun title(link: Link?): String = if (link == null) HomeRowNames.FOR_YOU else HomeRowNames.BECAUSE_YOU_WATCHED + " " + link.seedTitle
}
