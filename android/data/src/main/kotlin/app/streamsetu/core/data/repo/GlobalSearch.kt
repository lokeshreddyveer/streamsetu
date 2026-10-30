package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** What a result is. The order here is the order of the groups on the results screen, as on the iPhone. */
enum class SearchKind(val title: String) {
    CHANNEL("Live TV"), MOVIE("Movies"), SERIES("Series"), EPISODE("Episodes"), PROGRAMME("TV Guide"), FOLDER("Folders"), COLLECTION("Collections"),
    /** Sports: found in the Sports screens' own index and merged into the same list by the TV Search screen; [GlobalSearch] itself never returns these, and the phone never shows them. */
    SPORTS_EVENT("Sports"), SPORTS_TEAM("Teams"), SPORTS_COMPETITION("Competitions"), SPORTS_RECORDING("Sports recordings")
}

/** The Sports groups, in the order the TV Search screen lists them (after the library's own groups). */
val SportsSearchOrder = listOf(SearchKind.SPORTS_EVENT, SearchKind.SPORTS_TEAM, SearchKind.SPORTS_COMPETITION, SearchKind.SPORTS_RECORDING)

/** The order the groups of results are shown in, on every device: films and series first, then channels, then the rest. */
val SearchResultOrder = listOf(SearchKind.MOVIE, SearchKind.SERIES, SearchKind.CHANNEL, SearchKind.EPISODE, SearchKind.PROGRAMME, SearchKind.FOLDER, SearchKind.COLLECTION)

/** The short label that says what kind of thing a result is. */
fun SearchKind.badge(): String = when (this) {
    SearchKind.CHANNEL -> "LIVE"; SearchKind.MOVIE -> "MOVIE"; SearchKind.SERIES -> "SERIES"; SearchKind.EPISODE -> "EPISODE"
    SearchKind.PROGRAMME -> "GUIDE"; SearchKind.FOLDER -> "FOLDER"; SearchKind.COLLECTION -> "COLLECTION"
    SearchKind.SPORTS_EVENT -> "SPORTS"; SearchKind.SPORTS_TEAM -> "TEAM"; SearchKind.SPORTS_COMPETITION -> "COMPETITION"; SearchKind.SPORTS_RECORDING -> "RECORDING"
}

/** The result whose title is exactly what was typed, if there is one. It is shown first, ahead of everything else. */
fun GlobalResults.exactMatch(query: String): SearchItem? {
    val want = SearchText.normalize(query.trim())
    if (want.isEmpty()) return null
    return SearchResultOrder.flatMap { byKind[it].orEmpty() }.firstOrNull { SearchText.normalize(it.title) == want }
}

/** Where a search was started: from Home (everything), or from Live TV, Movies or Series (only that kind, shown as tiles). */
enum class SearchTab(val label: String, val kinds: Set<SearchKind>) {
    ALL("All", SearchKind.entries.toSet()),
    EPISODES("Episodes", setOf(SearchKind.EPISODE)),
    GUIDE("TV Guide", setOf(SearchKind.PROGRAMME)),
    LIVE("Live TV", setOf(SearchKind.CHANNEL)),
    MOVIES("Movies", setOf(SearchKind.MOVIE)),
    SERIES("Series", setOf(SearchKind.SERIES)),
}

/** What choosing a result does. */
sealed interface SearchTarget {
    data class PlayChannel(val channel: Channel) : SearchTarget
    data class OpenMovie(val movie: Movie) : SearchTarget
    data class OpenSeries(val series: Series) : SearchTarget
    data class PlayEpisode(val episode: Episode, val series: Series) : SearchTarget
    /** A programme in the guide: its channel (already checked against the open library) and when it is on, as stored (before the guide time shift). Choosing it opens that programme in the Guide. */
    data class PlayProgramme(val channel: Channel, val startMs: Long = 0L, val endMs: Long = 0L) : SearchTarget
    data class OpenFolder(val kind: ContentKind, val folderId: String) : SearchTarget
    data class OpenCollection(val id: String, val kind: ContentKind) : SearchTarget
    /** A Sports event, team, competition or recording. Plain text only: the Sports screens work out what it means (see SportsLink). */
    data class OpenSports(val kind: String, val key: String, val sport: String, val name: String, val eventId: String?) : SearchTarget
}

data class SearchItem(val id: String, val kind: SearchKind, val title: String, val subtitle: String, val artworkUrl: String?, val target: SearchTarget, val score: Int)

/** [more]: the groups that have further results beyond what is listed ("Show more"). */
data class GlobalResults(val byKind: Map<SearchKind, List<SearchItem>> = emptyMap(), val correctedTo: String? = null, val understood: List<String> = emptyList(), val more: Set<SearchKind> = emptySet()) {
    val isEmpty get() = byKind.values.all { it.isEmpty() }
    fun flat(tab: SearchTab): List<SearchItem> = SearchKind.entries.filter { it in tab.kinds }.flatMap { byKind[it].orEmpty() }
}

/**
 * One search over everything in the open library, the way the iPhone app does it:
 *  - channels, movies, series, episodes already downloaded, programmes in the guide, folders and collections, each in its own group;
 *  - "hindi movies 2024" means Hindi titles from 2024 (the year narrows, "movies" is dropped);
 *  - when nothing is found it tries a spelling fix taken from the words in the library, and reports what it searched for instead.
 * Everything runs against the stored catalog on this device; no provider is asked. Locked folders never show up.
 */
class GlobalSearch(
    private val db: AppDatabase,
    private val library: LibraryRepository,
    private val folders: FolderRepository,
    private val collections: CollectionRepository,
    private val search: SearchRepository,
    private val sourceName: suspend (String) -> String?,
) {
    suspend fun search(typed: String, tab: SearchTab = SearchTab.ALL, limit: Int = if (tab == SearchTab.ALL) 12 else 60, extra: Map<SearchKind, Int> = emptyMap()): GlobalResults = searchCore(typed, tab, limit, extra) { }

    /**
     * The same search, shown as it is found: the titles first (movies, series and channels together, from the text index), then episodes, the guide, folders and collections, each added below what
     * is already there so nothing that was shown moves. Every value is the whole result so far; the last one is the complete result. A slow guide or folder lookup never holds back the titles. Cancelling
     * the collector stops the work.
     */
    fun searchProgressive(typed: String, tab: SearchTab = SearchTab.ALL, limit: Int = if (tab == SearchTab.ALL) 12 else 60, extra: Map<SearchKind, Int> = emptyMap()): kotlinx.coroutines.flow.Flow<GlobalResults> = kotlinx.coroutines.flow.channelFlow {
        val last = searchCore(typed, tab, limit, extra) { send(it) }
        send(last)
    }

    private suspend fun searchCore(typed: String, tab: SearchTab, limit: Int, extra: Map<SearchKind, Int>, partial: suspend (GlobalResults) -> Unit): GlobalResults = withContext(Dispatchers.IO) {
        val q = typed.trim()
        if (SearchText.normalize(q).isBlank()) return@withContext GlobalResults()
        // A sentence ("telugu movies 2024 unwatched") is filters on films and series; when it finds nothing, the words are searched as a title below.
        val sentence = NaturalQuery.parse(q)
        if (sentence.isStructured && (SearchKind.MOVIE in tab.kinds || SearchKind.SERIES in tab.kinds)) {
            val found = forSentence(sentence, tab, limit)
            if (!found.isEmpty) return@withContext found.copy(understood = sentence.summary)
        }
        val parsed = SmartQuery.parse(q)
        val first = run(parsed.text.ifBlank { q }, tab, limit, parsed.year, extra, partial)
        if (!first.isEmpty) return@withContext first
        val alt = Spelling.correct(q, vocabulary()) ?: return@withContext first
        val p = SmartQuery.parse(alt)
        val again = run(p.text.ifBlank { alt }, tab, limit, p.year ?: parsed.year, extra) { }
        if (again.isEmpty) first else again.copy(correctedTo = alt)
    }

    /** Titles with somebody in them whose name has these words (the cast and directors read from the provider). */
    private fun people(kind: String, text: String): List<String> {
        if (text.replace(" ", "").length < 3) return emptyList()
        val ids = ArrayList<String>()
        db.openHelper.readableDatabase.query("SELECT DISTINCT itemId FROM people WHERE kind = ? AND norm LIKE ? LIMIT 400", arrayOf(kind, "%$text%")).use { c -> while (c.moveToNext()) ids += c.getString(0) }
        return ids
    }

    private suspend fun forSentence(n: NaturalQuery, tab: SearchTab, limit: Int): GlobalResults {
        val sources = library.sourceIds.value.toList()
        if (sources.isEmpty()) return GlobalResults()
        val locked = folders.lockedIdsNow()
        val terms = n.quality?.let { NaturalQuery.qualityTerms[it] ?: listOf(it) } ?: emptyList()
        val (q1, q2, q3) = Triple(terms.getOrNull(0).orEmpty(), terms.getOrNull(1) ?: terms.getOrNull(0).orEmpty(), terms.getOrNull(2) ?: terms.getOrNull(0).orEmpty())
        val text = SearchText.normalize(n.text)
        val since = if (n.recent) System.currentTimeMillis() - 30L * 86_400_000L else 0L
        val out = LinkedHashMap<SearchKind, List<SearchItem>>()
        fun sub(year: Int?, category: String?, vararg more: String?) = listOfNotNull(year?.toString(), *more).joinToString(" · ")
        if (SearchKind.MOVIE in tab.kinds) {
            val rows = db.catalog().moviesForSentence(sources, text, people("movie", text), n.year ?: 0, n.decade ?: 0, n.language.orEmpty(), q1, q2, q3, n.minRating ?: 0.0, if (n.unwatched) 1 else 0, if (n.favorites) 1 else 0, since, limit * 3 + 1)
                .filter { it.categoryId == null || it.categoryId !in locked }.take(limit)
            if (rows.isNotEmpty()) out[SearchKind.MOVIE] = rows.map { m -> m.toModel().let { SearchItem("movie:${m.id}", SearchKind.MOVIE, it.title, sub(it.year, null, it.rating?.takeIf { r -> r.isNotBlank() }?.let { r -> "\u2605 $r" }), it.posterUrl, SearchTarget.OpenMovie(it), 0) } }
        }
        if (SearchKind.SERIES in tab.kinds) {
            val rows = db.catalog().seriesForSentence(sources, text, people("series", text), n.year ?: 0, n.decade ?: 0, n.language.orEmpty(), q1, q2, q3, n.minRating ?: 0.0, if (n.unwatched) 1 else 0, if (n.favorites) 1 else 0, since, limit * 3 + 1)
                .filter { it.categoryId == null || it.categoryId !in locked }.take(limit)
            if (rows.isNotEmpty()) out[SearchKind.SERIES] = rows.map { s -> s.toModel().let { SearchItem("series:${s.id}", SearchKind.SERIES, it.title, sub(it.year, null, it.rating?.takeIf { r -> r.isNotBlank() }?.let { r -> "\u2605 $r" }), it.posterUrl, SearchTarget.OpenSeries(it), 0) } }
        }
        return GlobalResults(out)
    }

    /** Prepares the spelling word list in the background, so the first misspelt search is not slow. Call when the search screen opens. */
    suspend fun warmUp() = withContext(Dispatchers.IO) { runCatching { val t = System.currentTimeMillis(); vocabulary(); android.util.Log.i("Search", "spelling words ready in ${System.currentTimeMillis() - t} ms") } }

    private suspend fun run(text: String, tab: SearchTab, limit: Int, year: Int?, extra: Map<SearchKind, Int> = emptyMap(), partial: suspend (GlobalResults) -> Unit = { }): GlobalResults {
        val sources = library.sourceIds.value
        if (sources.isEmpty()) return GlobalResults()
        val multiple = sources.size > 1
        val raw = db.openHelper.readableDatabase
        val locked = folders.lockedIdsNow()
        val nq = SearchText.normalize(text)
        val out = LinkedHashMap<SearchKind, List<SearchItem>>()
        val more = LinkedHashSet<SearchKind>()
        fun capOf(kind: SearchKind) = limit + (extra[kind] ?: 0)
        fun put(kind: SearchKind, rows: List<SearchItem>) {
            val seen = HashSet<String>()
            val ranked = rows.filter { seen.add(it.id) }.withIndex().sortedWith(compareByDescending<IndexedValue<SearchItem>> { it.value.score }.thenBy { it.index }).map { it.value }
            if (ranked.isNotEmpty()) { out[kind] = ranked.take(capOf(kind)); if (ranked.size > capOf(kind)) more += kind }
        }
        suspend fun src(id: String) = if (multiple) sourceName(id) else null

        // Titles from the text index: one query per kind, so a huge catalog (movies) cannot crowd out the others.
        val cats = HashMap<String, String>()
        suspend fun categoryName(id: String?): String? {
            if (id == null) return null
            cats[id]?.let { return it }
            raw.query("SELECT name FROM categories WHERE id = ?", arrayOf(id)).use { c -> if (c.moveToFirst()) cats[id] = c.getString(0) }
            return cats[id]
        }
        if (SearchKind.CHANNEL in tab.kinds) {
            val r = search.search(text, SearchScope(kinds = setOf(ContentKind.CHANNEL)), capOf(SearchKind.CHANNEL) + 1).channels
            put(SearchKind.CHANNEL, r.map { ch -> SearchItem("channel:${ch.id}", SearchKind.CHANNEL, ch.name, listOfNotNull(categoryName(ch.categoryId), src(ch.sourceId)).joinToString(" · "), ch.logoUrl, SearchTarget.PlayChannel(ch), SearchText.score(ch.name, text)) })
        }
        if (SearchKind.MOVIE in tab.kinds) {
            val r = search.search(text, SearchScope(kinds = setOf(ContentKind.MOVIE)), capOf(SearchKind.MOVIE) * 3 + 1).movies
            put(SearchKind.MOVIE, r.map { m -> SearchItem("movie:${m.id}", SearchKind.MOVIE, m.title, listOfNotNull(m.year?.toString(), categoryName(m.categoryId), src(m.sourceId)).joinToString(" · "), m.posterUrl, SearchTarget.OpenMovie(m), SearchText.score(m.title, text)) })
        }
        if (SearchKind.SERIES in tab.kinds) {
            val r = search.search(text, SearchScope(kinds = setOf(ContentKind.SERIES)), capOf(SearchKind.SERIES) * 3 + 1).series
            put(SearchKind.SERIES, r.map { s -> SearchItem("series:${s.id}", SearchKind.SERIES, s.title, listOfNotNull(s.year?.toString(), categoryName(s.categoryId), src(s.sourceId)).joinToString(" · "), s.posterUrl, SearchTarget.OpenSeries(s), SearchText.score(s.title, text)) })
        }

        fun soFar(): GlobalResults = GlobalResults(if (year == null) LinkedHashMap(out) else out.mapValues { (_, rows) -> rows.filter { it.title.contains(year.toString()) || it.subtitle.contains(year.toString()) } }.filterValues { it.isNotEmpty() }, more = more.filter { it in out.keys }.toSet())
        if (out.isNotEmpty()) partial(soFar())                                    // the titles are on screen before the slower sources are asked

        // Episodes that are stored (a provider lists them per series, so only series that were opened have them).
        if (SearchKind.EPISODE in tab.kinds) {
            val ph = sources.joinToString(",") { "?" }
            val ids = ArrayList<Pair<String, String?>>()
            raw.query("SELECT e.id, s.categoryId FROM episodes e JOIN series s ON s.id = e.seriesId WHERE s.sourceId IN ($ph) AND e.title LIKE ? ESCAPE '\\' ORDER BY e.title LIMIT ?", (sources + like(text) + (capOf(SearchKind.EPISODE) + 1).toString()).toTypedArray()).use { c ->
                while (c.moveToNext()) ids += c.getString(0) to (if (c.isNull(1)) null else c.getString(1))
            }
            val rows = ids.filter { it.second == null || it.second !in locked }.mapNotNull { (id, _) ->
                val e = db.catalog().episode(id)?.toModel() ?: return@mapNotNull null
                val s = db.catalog().seriesByIds(listOf(e.seriesId)).firstOrNull()?.toModel() ?: return@mapNotNull null
                SearchItem("episode:${e.id}", SearchKind.EPISODE, e.title, listOfNotNull("${s.title} · S${e.season}E${e.number}", src(s.sourceId)).joinToString(" · "), e.imageUrl ?: s.posterUrl, SearchTarget.PlayEpisode(e, s), SearchText.score(e.title, text))
            }
            put(SearchKind.EPISODE, rows)
            if (rows.isNotEmpty()) partial(soFar())
        }

        // Programmes in the guide, from now on.
        if (SearchKind.PROGRAMME in tab.kinds) {
            // Guide ids are stored with the playlist they came from. They stay that way here: a programme belongs to a channel only of the same playlist (or, for a guide stored before ids were scoped,
            // to the channel carrying that id), so two playlists that happen to use the same guide id never swap programmes.
            class Prog(val stored: String, val start: Long, val end: Long, val title: String)
            val progs = ArrayList<Prog>()
            val inLibrary = sources.toSet()
            raw.query("SELECT channelEpgId, startMs, endMs, title FROM epg WHERE title LIKE ? ESCAPE '\\' AND endMs > ? ORDER BY startMs LIMIT ?", arrayOf(like(text), System.currentTimeMillis().toString(), ((capOf(SearchKind.PROGRAMME) + 1) * 6).toString())).use { c ->
                while (c.moveToNext()) { val stored = c.getString(0); val from = app.streamsetu.core.model.EpgIds.source(stored); if (from == null || from in inLibrary) progs += Prog(stored, c.getLong(1), c.getLong(2), c.getString(3)) }
            }
            if (progs.isNotEmpty()) {
                val rawIds = progs.map { app.streamsetu.core.model.EpgIds.raw(it.stored) }.distinct()
                val ph = sources.joinToString(",") { "?" }
                val byEpg = HashMap<String, String>()                    // playlist and guide id, together -> channel id
                rawIds.chunked(400).forEach { chunk ->
                    raw.query("SELECT sourceId, epgId, id FROM channels WHERE epgId IN (${chunk.joinToString(",") { "?" }}) AND sourceId IN ($ph)", (chunk + sources).toTypedArray()).use { c -> while (c.moveToNext()) byEpg.putIfAbsent(c.getString(0) + "\u0001" + c.getString(1), c.getString(2)) }
                }
                val channels = db.catalog().visibleChannelsByIds(byEpg.values.toList()).associate { it.id to it.toModel() }
                val fmt = SimpleDateFormat("EEE h:mm a", Locale.getDefault())
                put(SearchKind.PROGRAMME, progs.mapNotNull { p ->
                    val from = app.streamsetu.core.model.EpgIds.source(p.stored)
                    val channelId = if (from != null) byEpg[from + "\u0001" + app.streamsetu.core.model.EpgIds.raw(p.stored)] else sources.firstNotNullOfOrNull { s -> byEpg[s + "\u0001" + p.stored] }
                    val ch = channelId?.let { channels[it] } ?: return@mapNotNull null
                    if (ch.categoryId != null && ch.categoryId in locked) return@mapNotNull null
                    SearchItem("programme:${ch.id}:${p.start}", SearchKind.PROGRAMME, p.title, "${ch.name} · ${fmt.format(Date(p.start))}", ch.logoUrl, SearchTarget.PlayProgramme(ch, p.start, p.end), SearchText.score(p.title, text))
                })
                partial(soFar())
            }
        }

        // Folders and collections, matched by name.
        if (SearchKind.FOLDER in tab.kinds) {
            val rows = ArrayList<SearchItem>()
            for (k in listOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES)) {
                folders.folders(k).first().filter { !it.pref.hidden && !it.pref.locked && SearchText.normalize(it.title).contains(nq) }.forEach { f ->
                    val kindLabel = when (k) { ContentKind.CHANNEL -> "Live TV folder"; ContentKind.MOVIE -> "Movies folder"; else -> "Series folder" }
                    rows += SearchItem("folder:${f.id}", SearchKind.FOLDER, f.title, listOfNotNull(kindLabel, "%,d".format(f.count)).joinToString(" · "), null, SearchTarget.OpenFolder(k, f.id), SearchText.score(f.title, text))
                }
            }
            put(SearchKind.FOLDER, rows)
            if (rows.isNotEmpty()) partial(soFar())
        }
        if (SearchKind.COLLECTION in tab.kinds) {
            val rows = (collections.collections(ContentKind.MOVIE).first() + collections.collections(ContentKind.SERIES).first()).filter { SearchText.normalize(it.name).contains(nq) }
                .map { SearchItem("collection:${it.id}", SearchKind.COLLECTION, it.name, "Collection", null, SearchTarget.OpenCollection(it.id, it.scope), SearchText.score(it.name, text)) }
            put(SearchKind.COLLECTION, rows)
        }
        // "hindi movies 2024": only results whose title or subtitle holds the year stay, whatever their kind.
        val kept = if (year == null) out else out.mapValues { (_, rows) -> rows.filter { it.title.contains(year.toString()) || it.subtitle.contains(year.toString()) } }.filterValues { it.isNotEmpty() }
        return GlobalResults(kept, more = more.filter { it in kept.keys }.toSet())
    }

    /** `%term%` for a LIKE, with the characters LIKE treats specially made literal. */
    private fun like(text: String) = "%" + text.trim().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"

    // ---- Spelling vocabulary: the words in this library's titles and channel names, counted. Built once, kept until the library changes. ----
    @Volatile private var vocab: Pair<String, Map<String, Int>>? = null

    /** Counts the words of one title: letters and digits, at least three long, lower case, accents removed. Plain ASCII titles (nearly all) skip the slow accent step. */
    private fun addWords(title: String, counts: HashMap<String, Int>) {
        val t = if (title.all { it.code < 128 }) title else SearchText.normalize(title)
        var start = -1
        for (i in 0..t.length) {
            val ch = if (i < t.length) t[i] else ' '
            if (ch.isLetterOrDigit()) { if (start < 0) start = i }
            else if (start >= 0) { if (i - start >= 3) counts.merge(t.substring(start, i).lowercase(), 1, Int::plus); start = -1 }
        }
    }

    private fun vocabulary(): Map<String, Int> {
        val sources = library.sourceIds.value
        if (sources.isEmpty()) return emptyMap()
        val raw = db.openHelper.readableDatabase
        val rows = raw.query("SELECT COUNT(*) FROM ${app.streamsetu.core.data.db.SearchIndex.TABLE}").use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }
        val key = sources.joinToString(",") + "#" + rows
        vocab?.takeIf { it.first == key }?.let { return it.second }
        val counts = HashMap<String, Int>()
        raw.query("SELECT title FROM ${app.streamsetu.core.data.db.SearchIndex.TABLE} WHERE sourceId IN (${sources.joinToString(",") { "?" }})", sources.toTypedArray()).use { c ->
            while (c.moveToNext()) addWords(c.getString(0), counts)
        }
        vocab = key to counts
        return counts
    }
}
