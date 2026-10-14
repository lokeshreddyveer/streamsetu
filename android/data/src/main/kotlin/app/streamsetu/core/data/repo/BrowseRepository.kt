package app.streamsetu.core.data.repo

import android.content.Context
import androidx.sqlite.db.SimpleSQLiteQuery
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*

/**
 * Movies, series and channels for the Movies / Series / Live TV screens: a shortcut or folder, a sort, a limit.
 * The SQL is assembled from fixed pieces (never from typed text); values go in as bound arguments. Every query is limited to the open library,
 * leaves out locked folders until they are unlocked, and breaks ties by id so combined libraries keep a steady order.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class BrowseRepository(private val db: AppDatabase, private val library: LibraryRepository, private val folders: FolderRepository, context: Context) {
    private val prefs = context.getSharedPreferences("sort", Context.MODE_PRIVATE)
    private val sortFlows = HashMap<String, MutableStateFlow<SortSpec>>()

    /** The sort chosen for a section (Movies, Series, Live TV), or for one folder of it. Remembered on this device. */
    fun sort(kind: ContentKind, folderId: String? = null): MutableStateFlow<SortSpec> = synchronized(sortFlows) {
        val key = key(kind, folderId)
        sortFlows.getOrPut(key) { MutableStateFlow(SortSpec.decode(prefs.getString(key, null) ?: if (folderId != null) prefs.getString(key(kind, null), null) else null)) }
    }
    fun setSort(kind: ContentKind, folderId: String?, spec: SortSpec) {
        prefs.edit().putString(key(kind, folderId), spec.encode()).apply(); sort(kind, folderId).value = spec
    }
    private fun key(kind: ContentKind, folderId: String?) = "${kind.name}/${folderId ?: "*"}"

    suspend fun availability(): SortAvailability {
        val ids = library.sourceIds.value; val d = db.browse()
        return SortAvailability(
            year = d.moviesWithYear(ids) + d.seriesWithYear(ids) > 0, rating = d.moviesWithRating(ids) + d.seriesWithRating(ids) > 0,
            duration = false, recentlyWatched = d.watchedCount() > 0,
        )
    }

    fun movies(browse: Browse, sort: SortSpec, limit: Int = 600): Flow<List<Movie>> = query(ContentKind.MOVIE, browse, sort, limit) { db.browse().movies(it).map { l -> l.map { e -> e.toModel() } } }
    fun series(browse: Browse, sort: SortSpec, limit: Int = 600): Flow<List<Series>> = query(ContentKind.SERIES, browse, sort, limit) { db.browse().series(it).map { l -> l.map { e -> e.toModel() } } }
    fun channels(browse: Browse, sort: SortSpec, limit: Int = 3000): Flow<List<Channel>> = query(ContentKind.CHANNEL, browse, sort, limit) { db.browse().channels(it).map { l -> l.map { e -> e.toModel() } } }

    private fun <T> query(kind: ContentKind, browse: Browse, sort: SortSpec, limit: Int, run: (androidx.sqlite.db.SupportSQLiteQuery) -> Flow<T>): Flow<T> =
        combine(library.sourceIds, folders.lockedIds(kind), db.browse().favoriteFolders(kind.name)) { ids, locked, favFolders -> Triple(ids, locked, favFolders) }
            .flatMapLatest { (ids, locked, favFolders) -> run(build(kind, browse, sort, limit, ids, locked, favFolders)) }

    private fun build(kind: ContentKind, browse: Browse, sort: SortSpec, limit: Int, sources: List<String>, locked: Set<String>, favFolders: List<String>): SimpleSQLiteQuery {
        val table = when (kind) { ContentKind.MOVIE -> "movies"; ContentKind.SERIES -> "series"; else -> "channels" }
        val title = if (kind == ContentKind.CHANNEL) "x.name" else "x.title"
        val args = ArrayList<Any?>()
        val where = ArrayList<String>()
        val joins = StringBuilder()
        where += "x.sourceId IN (${sources.joinToString(",") { "?" }})"; args.addAll(sources)
        if (sources.isEmpty()) where += "1 = 0"
        if (locked.isNotEmpty()) { where += "(x.categoryId IS NULL OR x.categoryId NOT IN (${locked.joinToString(",") { "?" }}))"; args.addAll(locked) }

        fun inList(list: String) = "EXISTS (SELECT 1 FROM favorites f WHERE f.itemId = x.id AND f.listId = '$list')"
        when (browse) {
            Browse.All, Browse.RecentlyAdded -> {}
            is Browse.Folder -> { where += "x.categoryId = ?"; args += browse.id }
            Browse.FavoriteFolders -> { where += if (favFolders.isEmpty()) "1 = 0" else "x.categoryId IN (${favFolders.joinToString(",") { "?" }})"; args.addAll(favFolders) }
            Browse.Favorites -> where += inList(UserRepository.FAVOURITES)
            Browse.WatchLater -> where += inList(UserRepository.WATCH_LATER)
            Browse.Continue -> where += when (kind) {
                ContentKind.MOVIE -> "EXISTS (SELECT 1 FROM progress p WHERE p.itemId = x.id AND p.completed = 0 AND p.positionMs > 30000)"
                ContentKind.SERIES -> "EXISTS (SELECT 1 FROM progress p WHERE p.seriesId = x.id AND p.completed = 0 AND p.positionMs > 30000)"
                else -> "1 = 0"
            }
            Browse.Recent -> where += when (kind) {
                ContentKind.SERIES -> "x.id IN (SELECT e.seriesId FROM episodes e JOIN watch_log w ON w.itemId = e.id)"
                else -> "EXISTS (SELECT 1 FROM watch_log w WHERE w.itemId = x.id)"
            }
        }

        val order = ArrayList<String>()
        if (sort.favoritesFirst) order += "(NOT ${inList(UserRepository.FAVOURITES)}) ASC"
        if (sort.unwatchedFirst && kind != ContentKind.CHANNEL) order += when (kind) {
            ContentKind.SERIES -> "(x.id IN (SELECT seriesId FROM progress WHERE seriesId IS NOT NULL)) ASC"
            else -> "(EXISTS (SELECT 1 FROM progress p WHERE p.itemId = x.id)) ASC"
        }
        // The field itself. "Natural" is the first direction named in the label (A to Z, newest first, highest first).
        val field = if (browse == Browse.RecentlyAdded && sort.field == SortField.PROVIDER) SortField.ADDED else sort.field
        val flip = !sort.ascending
        fun dir(natural: String) = if (flip) (if (natural == "ASC") "DESC" else "ASC") else natural
        val primary = when (field) {
            SortField.PROVIDER -> "x.rowid ${dir("ASC")}"
            SortField.NAME -> "$title COLLATE NOCASE ${dir("ASC")}"
            SortField.ADDED -> "x.addedAt ${dir("DESC")}"
            SortField.RECENTLY_WATCHED -> { joins.append(" LEFT JOIN (SELECT itemId, MAX(playedAt) AS lastPlayed FROM watch_log GROUP BY itemId) w ON w.itemId = x.id"); "(w.lastPlayed IS NULL) ASC, w.lastPlayed ${dir("DESC")}" }
            SortField.YEAR -> if (kind == ContentKind.CHANNEL) "x.rowid ASC" else "(x.year IS NULL) ASC, x.year ${dir("DESC")}"
            SortField.RATING -> if (kind == ContentKind.CHANNEL) "x.rowid ASC" else "(x.rating IS NULL OR x.rating = '' OR CAST(x.rating AS REAL) = 0) ASC, CAST(x.rating AS REAL) ${dir("DESC")}"
            SortField.DURATION -> "x.rowid ASC"
        }
        order += primary; order += "x.id ASC"
        val sql = "SELECT x.* FROM $table x$joins WHERE ${where.joinToString(" AND ")} ORDER BY ${order.joinToString(", ")} LIMIT $limit"
        return SimpleSQLiteQuery(sql, args.toTypedArray())
    }
}
