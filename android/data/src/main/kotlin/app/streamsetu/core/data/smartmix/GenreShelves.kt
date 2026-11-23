package app.streamsetu.core.data.smartmix

import java.util.Locale

/** The ranked lists behind a shelf (docs/SMART-MIX.md section 5), read from the saved copy only: never a request. */
fun interface RankedLists { fun entries(name: String, nowMillis: Long): List<TrendingEntry>? }

/** Which list a ranking shelf follows: this week's trending, or the all-time top. */
enum class ShelfView { WEEKLY, ALL_TIME;
    companion object { fun parse(s: String?) = if (s == "allTime") ALL_TIME else WEEKLY }
    val wire: String get() = if (this == ALL_TIME) "allTime" else "weekly"
}

/**
 * Genre shelves (docs/SMART-MIX.md sections 1 to 6), the same rules as the Apple reference, integers only: text rules, which genres match a title, which shelves show today,
 * where they sit on Home, the remembered view per profile and shelf, and the names of the TMDB lists behind them.
 */
object GenreShelves {
    const val PREFIX = "genre:"
    const val MIN_TITLES = 8
    const val MAX_SHOWN = 6
    const val MAX_FROM_AFFINITY = 3
    const val RANK_BUCKET = 3
    const val SHELF_SIZE = 14
    /** The most genre shelves directly after one another on Home. */
    const val MAX_IN_A_ROW = 2

    val WEEKLY_WEIGHTS = Weights(15, 10, 10, 5, 25, 25, 0, 10)
    val ALL_TIME_WEIGHTS = Weights(5, 0, 15, 5, 50, 15, 0, 10)

    // ---- text rules
    /** Lowercase; every run of characters that are not letters or digits becomes one space; trimmed. "Sci-Fi & Fantasy" -> "sci fi fantasy". */
    fun norm(s: String): String {
        val low = s.lowercase(Locale.ROOT)
        val sb = StringBuilder(low.length)
        var gap = false
        var i = 0
        while (i < low.length) {
            val cp = low.codePointAt(i); i += Character.charCount(cp)
            if (Character.isLetterOrDigit(cp)) { if (gap && sb.isNotEmpty()) sb.append(' '); gap = false; sb.appendCodePoint(cp) } else gap = true
        }
        return sb.toString()
    }

    /** The provider's genre text split on , / | ; then normalised; empties and duplicates dropped, order kept. */
    fun tokens(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        val out = LinkedHashSet<String>()
        for (part in raw.split(',', '/', '|', ';')) norm(part).takeIf { it.isNotEmpty() }?.let { out.add(it) }
        return out.toList()
    }

    /** A token matches an alias when equal, or when the alias occurs in the token as whole words. */
    fun tokenMatches(token: String, alias: String) = token == alias || " $token ".contains(" $alias ")

    fun matches(g: GenreDef, tokens: List<String>, series: Boolean): Boolean {
        if (tokens.isEmpty()) return false
        if (g.scope == GenreScope.MOVIE && series) return false
        if (g.scope == GenreScope.SERIES && !series) return false
        return tokens.any { t -> g.aliases.any { a -> tokenMatches(t, a) } }
    }

    /** The genre keys a title belongs to, in table order. */
    fun keysFor(tokens: List<String>, series: Boolean): List<String> = GenreTable.all.filter { matches(it, tokens, series) }.map { it.key }

    /** The words a title's TMDB genre ids stand for: one alias per genre (movie ids for a film, tv ids for a series). They are added to the title's genre text, ahead of the folder's words. */
    fun tokensForTmdb(ids: List<Int>, series: Boolean): List<String> = GenreTable.all.filter { g -> (if (series) g.tmdbTV else g.tmdbMovie).any { it in ids } && (g.scope != GenreScope.MOVIE || !series) && (g.scope != GenreScope.SERIES || series) }.map { it.aliases.first() }

    fun matches(g: GenreDef, c: Candidate) = matches(g, c.genres, c.kind == Kind.SERIES)

    // ---- which shelves show today
    /** Clusters per genre that are not restricted, not dismissed, not CAM-only, have a poster, and match (kind allowed). [groups] are the representatives of [IdentityGrouping.prepare]. */
    fun counts(groups: List<Candidate>): Map<String, Int> {
        val m = LinkedHashMap<String, Int>()
        for (c in groups) {
            if (c.restricted || c.dismissed || c.camOnly || !c.hasPoster || c.genres.isEmpty()) continue
            for (k in keysFor(c.genres, c.kind == Kind.SERIES)) m[k] = (m[k] ?: 0) + 1
        }
        return m
    }

    /** The genres of the titles watched most lately (the 3 most common, most first, ties in table order). Input: genre tokens of each recently watched title and its kind. */
    fun affinityKeys(recent: List<Pair<List<String>, Boolean>>): List<String> {
        val n = HashMap<String, Int>()
        for ((tokens, series) in recent) for (k in keysFor(tokens, series)) n[k] = (n[k] ?: 0) + 1
        val order = GenreTable.all.map { it.key }
        return n.keys.sortedWith(compareBy({ -n[it]!! }, { order.indexOf(it) })).take(MAX_FROM_AFFINITY)
    }

    /** At most [MAX_SHOWN] genre shelves for today: the person's own genres first, then the rest of the table rotated by the day. */
    fun select(counts: Map<String, Int>, profileId: String, dayKey: String, refreshCounter: Int, kids: Boolean, affinityKeys: List<String>): List<String> {
        val eligible = GenreTable.all.filter { (counts[it.key] ?: 0) >= MIN_TITLES && (!kids || it.kids) }.map { it.key }
        val chosen = ArrayList<String>()
        for (k in affinityKeys) { if (chosen.size >= MAX_FROM_AFFINITY) break; if (k in eligible && k !in chosen) chosen.add(k) }
        val rest = eligible.filter { it !in chosen }
        if (rest.isNotEmpty() && chosen.size < MAX_SHOWN) {
            val off = SmartMixSeed.rng(profileId, "genres:auto", dayKey, refreshCounter).uniform(rest.size.toULong()).toInt()
            val rotated = rest.drop(off) + rest.take(off)
            chosen.addAll(rotated.take(MAX_SHOWN - chosen.size))
        }
        return chosen
    }

    /** Every eligible genre in table order with its count: the "Browse by genre" row. */
    fun browse(counts: Map<String, Int>, kids: Boolean): List<Pair<GenreDef, Int>> =
        GenreTable.all.filter { (counts[it.key] ?: 0) >= MIN_TITLES && (!kids || it.kids) }.map { it to counts[it.key]!! }

    // ---- placement on Home
    private val TEMPLATE = listOf("top-week", "trending", "G", "for-you", "G", "G", "lang-pref", "G", "rediscover", "G", "G")

    /** Home order of the personalised shelves with the genre shelves ([genres], in the chosen order) between them; a genre shelf is placed only when fewer than 2 genre shelves come directly before it. */
    fun placement(present: Set<String>, genres: List<String>): List<String> {
        val out = ArrayList<String>(); var next = 0; var run = 0
        for (t in TEMPLATE) {
            if (t == "G") {
                if (next < genres.size && run < MAX_IN_A_ROW) { out.add(genres[next++]); run++ }
            } else if (t in present) { out.add(t); run = 0 }
        }
        return out
    }

    // ---- the lists behind a shelf
    /** (own list, whole-library list) for a shelf and view: genre:thriller weekly = ("week:thriller", "week"); trending-library has no list of its own. */
    fun listNames(shelfId: String, view: ShelfView): Pair<String, String> {
        val general = if (view == ShelfView.ALL_TIME) "top" else "week"
        val g = GenreTable.ofShelf(shelfId) ?: return "" to general
        return "$general:${g.key}" to general
    }
    /** "week" lists are refetched after 24 hours, the others after 168 (a week). */
    fun refetchHours(listName: String) = if (listName.startsWith("week")) 24 else 168
}

/** The remembered view per profile and shelf (`smartmix.mode.<profile>.<shelfId>`); both views are stored. [raw] is any string store (SharedPreferences in the app). */
class ShelfModeStore(private val get: (String) -> String?, private val put: (String, String?) -> Unit) {
    private fun key(profileId: String, shelfId: String) = "smartmix.mode.$profileId.$shelfId"
    fun mode(profileId: String, shelfId: String): ShelfView = ShelfView.parse(get(key(profileId, shelfId)))
    /** The person's own choice, or null when they never tapped a segment (section 10.6: a tap on either segment is stored, "This week" included; an older all-time value counts). */
    fun chosen(profileId: String, shelfId: String): ShelfView? = get(key(profileId, shelfId))?.let { ShelfView.parse(it) }
    fun set(profileId: String, shelfId: String, view: ShelfView) = put(key(profileId, shelfId), view.wire)
}
