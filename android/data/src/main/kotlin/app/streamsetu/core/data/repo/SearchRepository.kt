package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.SearchHit
import app.streamsetu.core.data.db.SearchIndex
import app.streamsetu.core.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext

/** What the person asked for: which kinds, in which library connections, optionally one folder or year. */
data class SearchScope(val kinds: Set<ContentKind> = setOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES), val sourceId: String? = null, val folderId: String? = null, val year: Int? = null)

/**
 * Local search over the text index. Typed words are matched as prefixes; hits are ranked (exact title, prefix, whole word, partial) and ties break by id.
 * A short result list is topped up with a bounded fuzzy pass over a small candidate set. Locked folders and disabled connections never appear.
 * The caller debounces typing and cancels the previous call when the text changes.
 */
class SearchRepository(private val db: AppDatabase, private val library: LibraryRepository, private val folders: FolderRepository, context: Context) {
    private val prefs = context.getSharedPreferences("search", Context.MODE_PRIVATE)
    private val _recent = MutableStateFlow(prefs.getString("recent", "").orEmpty().split('\n').filter { it.isNotBlank() })
    val recent: StateFlow<List<String>> = _recent

    fun remember(query: String) {
        val q = query.trim(); if (q.length < 2) return
        val list = (listOf(q) + _recent.value.filter { !it.equals(q, true) }).take(10)
        prefs.edit().putString("recent", list.joinToString("\n")).apply(); _recent.value = list
    }
    /** Recent searches kept apart for each screen they were made on (Home, Live TV, Movies, Series), newest first, as on the iPhone. */
    fun recentIn(scope: String): List<String> = prefs.getString("recent.$scope", "").orEmpty().split('\n').filter { it.isNotBlank() }
    fun rememberIn(scope: String, query: String) {
        val q = query.trim(); if (q.length < 2) return
        val list = (listOf(q) + recentIn(scope).filter { !it.equals(q, true) }).take(8)
        prefs.edit().putString("recent.$scope", list.joinToString("\n")).apply()
    }
    fun clearIn(scope: String) { prefs.edit().remove("recent.$scope").apply() }

    fun clearHistory() { prefs.edit().remove("recent").apply(); _recent.value = emptyList() }

    suspend fun search(typed: String, scope: SearchScope = SearchScope(), limit: Int = 60): SearchResults = withContext(Dispatchers.IO) {
        val match = SearchText.matchQuery(typed)
        if (match.isEmpty()) return@withContext SearchResults()
        val sources = scope.sourceId?.let { listOf(it) } ?: library.sourceIds.value
        val locked = folders.lockedIdsNow()
        val kinds = scope.kinds.map { it.name }
        val raw = db.openHelper.readableDatabase
        var hits = SearchIndex.query(raw, match, sources, kinds, 400)
        if (hits.size < 6 && SearchText.normalize(typed).length >= 4) {
            // Probably a typo: a few candidates that share the first letters, re-ranked by edit distance.
            val seed = SearchText.tokens(typed).first().take(3) + "*"
            val extra = SearchIndex.query(raw, seed, sources, kinds, 300).filter { h -> hits.none { it.itemId == h.itemId } }
                .filter { SearchText.fuzzyScore(it.title, typed) > 0 }
            hits = hits + extra
        }
        hits = hits.filter { it.folderId == null || it.folderId !in locked }.filter { scope.folderId == null || it.folderId == scope.folderId }
        val ranked = hits.map { it to maxOf(SearchText.score(it.title, typed), SearchText.fuzzyScore(it.title, typed)) }.filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<SearchHit, Int>> { it.second }.thenBy { it.first.title.length }.thenBy { it.first.itemId }).map { it.first }
        // One logical title across combined sources shows once (same normalised title, same kind), keeping the first connection's record.
        val seen = HashSet<String>()
        val unique = ranked.filter { seen.add(it.kind + "|" + SearchText.normalize(it.title)) }.take(limit)
        fun ids(kind: ContentKind) = unique.filter { it.kind == kind.name }.map { it.itemId }
        val order = unique.withIndex().associate { it.value.itemId to it.index }
        val c = db.catalog()
        var movies = if (ContentKind.MOVIE in scope.kinds) c.moviesByIds(ids(ContentKind.MOVIE)).map { it.toModel() } else emptyList()
        var series = if (ContentKind.SERIES in scope.kinds) c.seriesByIds(ids(ContentKind.SERIES)).map { it.toModel() } else emptyList()
        val channels = if (ContentKind.CHANNEL in scope.kinds) c.channelsByIds(ids(ContentKind.CHANNEL)).map { it.toModel() } else emptyList()
        if (scope.year != null) { movies = movies.filter { it.year == scope.year }; series = series.filter { it.year == scope.year } }
        SearchResults(channels.sortedBy { order[it.id] }, movies.sortedBy { order[it.id] }, series.sortedBy { order[it.id] })
    }

    /** A few titles to offer while typing (beginning with what has been typed). */
    suspend fun suggestions(typed: String, limit: Int = 6): List<String> = withContext(Dispatchers.IO) {
        val match = SearchText.matchQuery(typed); if (match.isEmpty()) return@withContext emptyList()
        val locked = folders.lockedIdsNow()
        SearchIndex.query(db.openHelper.readableDatabase, match, library.sourceIds.value, listOf("MOVIE", "SERIES", "CHANNEL"), 80)
            .filter { it.folderId == null || it.folderId !in locked }
            .sortedWith(compareByDescending<SearchHit> { SearchText.score(it.title, typed) }.thenBy { it.title.length }.thenBy { it.itemId })
            .map { it.title }.distinctBy { SearchText.normalize(it) }.take(limit)
    }

    /** The same title in other connections of the open library (for "Choose Stream" / "Choose Source"). Never merges different titles. */
    suspend fun movieVariants(title: String): List<Movie> = withContext(Dispatchers.IO) {
        val norm = SearchText.normalize(title)
        val hits = SearchIndex.query(db.openHelper.readableDatabase, SearchText.matchQuery(title), library.sourceIds.value, listOf("MOVIE"), 80).filter { SearchText.normalize(it.title) == norm }
        db.catalog().moviesByIds(hits.map { it.itemId }).map { it.toModel() }.sortedBy { it.sourceId }
    }
    suspend fun seriesVariants(title: String): List<Series> = withContext(Dispatchers.IO) {
        val norm = SearchText.normalize(title)
        val hits = SearchIndex.query(db.openHelper.readableDatabase, SearchText.matchQuery(title), library.sourceIds.value, listOf("SERIES"), 80).filter { SearchText.normalize(it.title) == norm }
        db.catalog().seriesByIds(hits.map { it.itemId }).map { it.toModel() }.sortedBy { it.sourceId }
    }
}
