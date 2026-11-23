package app.streamsetu.core.data.smartmix

/** Pure, deterministic, integer-only. Same (library, context, shelf) gives the same ordered ids on every platform. */
object SmartMixEngine {
    private class Scored(val c: Candidate, val s: Int)

    private class Pass(val tier: Int, val counts: IntArray, val tiny: Boolean, val items: List<Scored>, val picks: List<Int>, val diversityRelaxed: Boolean, val ordered: Boolean = false)

    private const val C_CAM = 0
    private const val C_ART = 1
    private const val C_LANG = 2
    private const val C_NOTREND = 3
    private const val C_WATCHED = 4

    fun score(c: Candidate, spec: ShelfSpec, ctx: Context, relax: Int): Int {
        val w = spec.weights
        val sum = w.release.toLong() * Features.release(c.year, ctx.nowYear) +
            w.added.toLong() * Features.added(c.addedDays) +
            w.quality.toLong() * Features.quality(c.qualityRank) +
            w.language.toLong() * Features.language(c.lang, ctx.preferredLang) +
            w.rating.toLong() * Features.rating(c.ratingText) +
            w.popularity.toLong() * Features.popularity(c.plays7, c.plays30) +
            w.affinity.toLong() * Features.affinity(c, ctx.affinity) +
            w.fresh.toLong() * (if (relax >= 1) 1000 else Features.fresh(c.loadsAgo))
        var s = (sum / 100).toInt()
        if (spec.id == ShelfSpec.HERO) { if (c.hasBackdrop) s += 50; if (c.trendingRank != null) s += 60 }
        else if ((spec.id == ShelfSpec.TOP_WEEK || spec.id == ShelfSpec.TRENDING_LIBRARY) && c.trendingRank != null) s += 100
        if (relax >= 3 && c.watched && spec.id != ShelfSpec.REDISCOVER) s -= 200
        return s.coerceIn(0, 1100)
    }

    fun weight(s: Int, sharp: Boolean): Long = if (sharp) 1L + s.toLong() * s / 100 else 1L + s

    fun buildShelf(prep: Prepared, shelfId: String, ctx: Context, trendingOrdered: Boolean, view: ShelfView = ShelfView.WEEKLY): ShelfResult {
        var spec = ShelfSpec.of(shelfId, view, ctx.kids)
        val allTime = view == ShelfView.ALL_TIME
        val genre = spec.genre
        var restricted = 0; var dismissed = 0
        val source: List<Candidate> = if (spec.isFolder) (prep.byFolder[spec.folderKey] ?: emptyList()) else if (genre != null) prep.groups.filter { GenreShelves.matches(genre, it) } else if (spec.isContextRow) prep.groups.filter { contextMatch(spec, it) } else prep.groups
        var base = ArrayList<Candidate>(source.size)
        for (c in source) if (c.restricted) restricted++ else base.add(c)
        if (!spec.isFolder) {
            val keep = ArrayList<Candidate>(base.size)
            for (c in base) if (c.dismissed) dismissed++ else keep.add(c)
            base = keep
        }
        fun diag(extra: ShelfDiagnostics.() -> ShelfDiagnostics = { this }) =
            ShelfDiagnostics(inCount = prep.inCount, groups = source.size, restricted = restricted, dismissed = dismissed).extra()

        if (shelfId == ShelfSpec.LANG_PREF && ctx.preferredLang.isNullOrEmpty())
            return ShelfResult(shelfId, emptyList(), emptyList(), diag { copy(hidden = true) })

        val need = minOf(spec.minCount, base.size)
        val trendMode = shelfId == ShelfSpec.TRENDING_LIBRARY && base.count { it.trendingRank != null } >= 3
        // The all-time view of Trending in Your Library uses the all-time weights (and the seed "trending-library|top") whether or not titles of the list matched.
        if (allTime && shelfId == ShelfSpec.TRENDING_LIBRARY) spec = spec.withWeights(GenreShelves.ALL_TIME_WEIGHTS)
        val seedId = if (allTime && (shelfId == ShelfSpec.TRENDING_LIBRARY || genre != null)) "$shelfId|top" else shelfId
        var last: Pass? = null
        for (tier in 0..5) {
            val p = pass(base, spec, ctx, trendingOrdered, trendMode, tier, seedId)
            last = p
            if (p.picks.size >= need) break
        }
        val p = last!!
        var out: List<Candidate> = p.picks.map { p.items[it].c }
        var fallback = "none"
        var hidden = false
        if (genre != null) {
            // A genre shelf has no fallback: fewer than 8 titles and it is not shown.
            if (out.size < GenreShelves.MIN_TITLES) { out = emptyList(); hidden = true }
        } else if (spec.isContextRow) {
            // Fresh, Movie Night, Binge and the moods have no fallback: a row that needed poster-less or CAM-only titles, or has too few, is not shown. A mood also needs its floor (1.5% of the library, at least 8).
            val showable = base.count { !it.camOnly && it.hasPoster }
            val floor = if (spec.moodKeys != null) HomeMoods.floor(if (ctx.libraryTotal > 0) ctx.libraryTotal else 0) else ShelfSpec.CONTEXT_MIN
            if (p.tier >= Relax.ARTWORK || p.picks.size < ShelfSpec.CONTEXT_MIN || showable < floor) { out = emptyList(); hidden = true }
        } else if (out.isEmpty() && shelfId != ShelfSpec.LANG_PREF) {
            var rec = base.filter { it.hasPoster || it.hasBackdrop }.sortedWith { a, b -> addedThenId(a, b) }
            fallback = "recentlyAdded"
            if (rec.isEmpty()) { rec = base.sortedWith { a, b -> compareUtf8(a.id, b.id) }; fallback = "plainLibrary" }
            out = rec.take(spec.size)
            if (out.isEmpty()) fallback = if (shelfId == ShelfSpec.HERO) "existingFeatured" else "none"
        } else if (out.isEmpty()) hidden = true
        val c = p.counts
        val d = diag {
            copy(camOnly = c[C_CAM], noArtwork = c[C_ART], watched = c[C_WATCHED], lang = c[C_LANG], notTrending = c[C_NOTREND],
                pool = p.items.size, drawn = p.picks.size, tier = p.tier, tiny = p.tiny, hidden = hidden, fallback = fallback, diversityRelaxed = p.diversityRelaxed,
                trendMode = trendMode || (genre != null && p.ordered),
                caption = if (spec.isContextRow) "" else if (genre != null) (if (hidden) "" else if (p.ordered) "trendingTMDB" else "mostWatchedHere") else when (shelfId) { ShelfSpec.TOP_WEEK -> if (trendingOrdered) "trendingTMDB" else "mostWatchedHere"; ShelfSpec.TRENDING_LIBRARY -> if (trendMode) "trendingTMDB" else "mostWatchedHere"; else -> "" })
        }
        return ShelfResult(shelfId, out.map { it.id }, if (shelfId == ShelfSpec.HERO) out.map { if (it.hasBackdrop) "backdrop" else "poster" } else emptyList(), d)
    }

    /** Eligibility of the Home v2 rows (section 10.2) at the candidate level: kind, freshness, quality and the rating floor (unrated titles pass), moods by their genre keys. */
    private fun contextMatch(spec: ShelfSpec, c: Candidate): Boolean {
        val tenths = Features.parseTenths(c.ratingText)
        return when (spec.id) {
            ShelfSpec.FRESH -> c.addedDays != null && c.addedDays <= ShelfSpec.FRESH_DAYS && (tenths == null || tenths >= 55)
            ShelfSpec.MOVIE_NIGHT -> c.kind == Kind.MOVIE && c.qualityRank >= 2 && (tenths == null || tenths >= 65)
            ShelfSpec.BINGE -> c.kind == Kind.SERIES && (tenths == null || tenths >= 65)
            else -> spec.moodKeys?.let { keys -> GenreShelves.keysFor(c.genres, c.kind == Kind.SERIES).any { it in keys } } ?: true
        }
    }

    private fun addedThenId(a: Candidate, b: Candidate): Int {
        if ((a.addedDays == null) != (b.addedDays == null)) return if (a.addedDays == null) 1 else -1
        val x = a.addedDays ?: 0; val y = b.addedDays ?: 0
        return if (x != y) x.compareTo(y) else compareUtf8(a.id, b.id)
    }

    private fun pass(base: List<Candidate>, spec: ShelfSpec, ctx: Context, trendingOrdered: Boolean, trendMode: Boolean, tier: Int, seedId: String): Pass {
        val id = spec.id
        val counts = IntArray(5)
        val elig = ArrayList<Candidate>(base.size)
        val pref = ctx.preferredLang
        for (c in base) {
            if (c.camOnly && tier < 5) { counts[C_CAM]++; continue }
            if (id == ShelfSpec.HERO) { if (!(c.hasBackdrop || c.hasPoster)) { counts[C_ART]++; continue } }
            else if (!c.hasPoster && tier < 4) { counts[C_ART]++; continue }
            if (id == ShelfSpec.LANG_PREF && c.lang != pref) { counts[C_LANG]++; continue }
            if (trendMode && c.trendingRank == null) { counts[C_NOTREND]++; continue }
            if (!spec.isFolder) {
                if (id == ShelfSpec.REDISCOVER) {
                    if (c.watched && (!c.completed || (c.lastWatchedDays != null && c.lastWatchedDays <= 30))) { counts[C_WATCHED]++; continue }
                } else if (c.watched && tier < 3) { counts[C_WATCHED]++; continue }
            }
            elig.add(c)
        }
        val tiny = elig.size <= spec.size
        val eff = if (tiny) maxOf(tier, 1) else tier

        val cap = if (spec.isFolder) minOf(spec.pool, ctx.poolCap ?: spec.pool) else (ctx.poolCap ?: spec.pool)
        val n = elig.size
        val sc = IntArray(n)
        for (i in 0 until n) sc[i] = score(elig[i], spec, ctx, eff)
        // order by (S desc, id bytes asc), keep the first `cap`: a score histogram finds the cutoff so only the survivors are sorted
        var cutoff = 0
        if (n > cap) {
            val h = IntArray(1101)
            for (s in sc) h[s]++
            var acc = 0; var s = 1100
            while (s >= 0) { acc += h[s]; if (acc >= cap) break; s-- }
            cutoff = maxOf(0, s)
        }
        val kept = ArrayList<Scored>()
        for (i in 0 until n) if (sc[i] >= cutoff) kept.add(Scored(elig[i], sc[i]))
        kept.sortWith { a, b -> if (a.s != b.s) b.s.compareTo(a.s) else compareUtf8(a.c.id, b.c.id) }
        val items: List<Scored> = if (kept.size > cap) kept.subList(0, cap) else kept

        var forced = IntArray(0)
        if (trendingOrdered && id == ShelfSpec.TOP_WEEK) {
            val order = items.indices.filter { items[it].c.trendingRank != null }.sortedWith { a, b ->
                val ra = items[a].c.trendingRank!!; val rb = items[b].c.trendingRank!!
                if (ra != rb) ra.compareTo(rb) else compareUtf8(items[a].c.id, items[b].c.id)
            }
            forced = order.take(spec.size).toIntArray()
        }
        val k = minOf(spec.size + maxOf(0, ctx.oversample), items.size)
        if (k == 0) return Pass(tier, counts, tiny, items, emptyList(), false)
        val rng = SmartMixSeed.rng(ctx.profileId, seedId, ctx.dayKey, ctx.refreshCounter)
        // A genre shelf follows a TMDB list when at least 6 of its titles are on it: ranks in the same bucket of 3 are shuffled by the day's stream, the buckets keep their order.
        var ordered = false
        if (spec.genre != null) {
            val matched = items.indices.filter { items[it].c.trendingRank != null }.sortedWith { a, b ->
                val ra = items[a].c.trendingRank!!; val rb = items[b].c.trendingRank!!
                if (ra != rb) ra.compareTo(rb) else compareUtf8(items[a].c.id, items[b].c.id)
            }
            if (matched.size >= ShelfSpec.TRENDING_MIN_MATCHES) {
                ordered = true
                val drawn = HashMap<Int, ULong>(); for (i in matched) drawn[i] = rng.next()
                forced = matched.sortedWith { a, b ->
                    val ba = (items[a].c.trendingRank!! - 1) / GenreShelves.RANK_BUCKET; val bb = (items[b].c.trendingRank!! - 1) / GenreShelves.RANK_BUCKET
                    if (ba != bb) ba.compareTo(bb) else if (drawn[a] != drawn[b]) drawn[a]!!.compareTo(drawn[b]!!) else compareUtf8(items[a].c.id, items[b].c.id)
                }.take(spec.size).toIntArray()
            }
        }
        val (picks, dr) = draw(items, k, spec, ctx, eff, forced, rng)
        return Pass(tier, counts, tiny, items, picks, dr, ordered)
    }

    private fun draw(items: List<Scored>, k: Int, spec: ShelfSpec, ctx: Context, relax: Int, forced: IntArray, rng: Rng64): Pair<List<Int>, Boolean> {
        val size = items.size
        val intern = HashMap<String, Int>()
        fun code(s: String?): Int = if (s == null) -1 else intern.getOrPut(s) { intern.size }
        val franchise = IntArray(size); val genre = IntArray(size); val lang = IntArray(size); val kind = IntArray(size)
        val w = LongArray(size)
        for (i in 0 until size) {
            val c = items[i].c
            franchise[i] = code(c.franchiseKey); genre[i] = code(c.primaryGenre); lang[i] = code(c.lang); kind[i] = c.kind.ordinal
            w[i] = weight(items[i].s, spec.sharp)
        }
        val div = relax < 2
        val langRule = spec.id != ShelfSpec.LANG_PREF
        val picks = ArrayList<Int>(k)
        for (i in forced) { w[i] = 0; picks.add(i) }
        var diagRelaxed = false
        val elig = IntArray(size)
        while (picks.size < k) {
            val np = picks.size
            val a = if (np >= 1) picks[np - 1] else -1; val b = if (np >= 2) picks[np - 2] else -1
            var ne = 0; var total = 0L
            for (i in 0 until size) {
                if (w[i] <= 0) continue
                if (div && np >= 2) {
                    if (franchise[i] >= 0 && franchise[a] == franchise[i] && franchise[b] == franchise[i]) continue
                    if (spec.genre == null && genre[i] >= 0 && genre[a] == genre[i] && genre[b] == genre[i]) continue
                    if (spec.mixesKinds && kind[a] == kind[i] && kind[b] == kind[i]) continue
                    if (langRule && lang[i] >= 0 && lang[a] == lang[i] && lang[b] == lang[i]) continue
                }
                elig[ne++] = i; total += w[i]
            }
            if (ne == 0) {
                for (i in 0 until size) if (w[i] > 0) { elig[ne++] = i; total += w[i] }
                if (ne > 0) diagRelaxed = true
            }
            if (total == 0L) break
            val r = rng.uniform(total.toULong()).toLong()
            var acc = 0L; var p = elig[ne - 1]
            for (e in 0 until ne) { acc += w[elig[e]]; if (r < acc) { p = elig[e]; break } }
            w[p] = 0; picks.add(p)
            if (div) {
                for (j in 0 until size) {
                    if (w[j] == 0L) continue
                    if (franchise[p] >= 0 && franchise[j] == franchise[p]) w[j] = w[j] / 4
                    if (langRule && lang[p] >= 0 && lang[j] == lang[p] && kind[j] == kind[p]) w[j] = (w[j] * 3) / 4
                }
            }
        }
        return picks to diagRelaxed
    }

    /** UTF-8 byte order == code point order. Not String.compareTo (UTF-16) and not locale based. */
    fun compareUtf8(a: String, b: String): Int {
        var i = 0; var j = 0
        while (i < a.length && j < b.length) {
            val ca = a.codePointAt(i); val cb = b.codePointAt(j)
            if (ca != cb) return if (ca < cb) -1 else 1
            i += Character.charCount(ca); j += Character.charCount(cb)
        }
        return (a.length - i).compareTo(b.length - j)
    }
}
