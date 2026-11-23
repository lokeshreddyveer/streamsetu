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
/** Where the next page starts: the last title of the page before it (its id, name and year). Reading from here is a seek in an index, not a count of everything before it. */
data class PageAfter(val id: String, val title: String, val year: Int?)

/** The two whole-library orders that are read straight from an index (see MIGRATION_11_12): "A to Z" and "newest year first". Everything else keeps its own query. */
enum class IndexPlan { NAME_ASC, YEAR_DESC, YEAR_NULLS }

@OptIn(ExperimentalCoroutinesApi::class)
class BrowseRepository(private val db: AppDatabase, private val library: LibraryRepository, private val folders: FolderRepository, context: Context) {
    private val prefs = context.getSharedPreferences("sort", Context.MODE_PRIVATE)
    private val sortFlows = HashMap<String, MutableStateFlow<SortSpec>>()

    /** The sort chosen for a section (Movies, Series, Live TV), or for one folder of it. Remembered on this device. */
    fun sort(kind: ContentKind, folderId: String? = null): MutableStateFlow<SortSpec> = synchronized(sortFlows) {
        val key = key(kind, folderId)
        sortFlows.getOrPut(key) { MutableStateFlow((prefs.getString(key, null) ?: if (folderId != null) prefs.getString(key(kind, null), null) else null)?.let { SortSpec.decode(it) } ?: SortSpec.defaultFor(kind)) }
    }
    fun setSort(kind: ContentKind, folderId: String?, spec: SortSpec) {
        prefs.edit().putString(key(kind, folderId), spec.encode()).apply(); sort(kind, folderId).value = spec
    }
    private fun key(kind: ContentKind, folderId: String?) = "${kind.name}/${folderId ?: "*"}"

    /** Both kinds together, for the screens that are not Movies or Series. */
    suspend fun availability(): SortAvailability {
        val ids = library.sourceIds.value; val m = availability(ids, ContentKind.MOVIE); val t = availability(ids, ContentKind.SERIES)
        return SortAvailability(m.year || t.year, m.rating || t.rating, m.duration || t.duration, m.recentlyWatched || t.recentlyWatched, m.seriesUpdated || t.seriesUpdated, m.newEpisodes || t.newEpisodes)
    }

    /** Which sorts apply to [kind] in exactly the [ids] sources it is asked about (not whatever library is open when the read happens). */
    suspend fun availability(ids: List<String>, kind: ContentKind = ContentKind.MOVIE): SortAvailability {
        val d = db.browse(); val movies = kind == ContentKind.MOVIE
        return SortAvailability(
            year = (if (movies) d.moviesWithYear(ids) else d.seriesWithYear(ids)) > 0, rating = (if (movies) d.moviesWithRating(ids) else d.seriesWithRating(ids)) > 0,
            duration = false, recentlyWatched = d.watchedCount() > 0, seriesUpdated = !movies && d.seriesWithUpdateDate(ids) > 0, newEpisodes = !movies && d.newEpisodeCount() > 0,
        )
    }

    /** Changes when a catalog was written (see [app.streamsetu.core.data.db.CatalogDao.catalogRevision]). */
    fun catalogRevision(): Flow<String> = db.catalog().catalogRevision()

    /**
     * One page of Movies or Series for exactly the library, restrictions and order it is asked for: nothing here looks at the open library or the locks again, so the result belongs to the
     * request that made it (a page started before a change can never be taken for the page after it).
     */
    suspend fun moviesPage(browse: Browse, sort: SortSpec, limit: Int, offset: Int, sources: List<String>, restricted: Set<String>, after: PageAfter? = null): List<Movie> =
        pageRows(ContentKind.MOVIE, browse, sort, limit, offset, sources, restricted, after) { q -> db.browse().moviesOnce(q).map { it.toModel() } }
    suspend fun seriesPage(browse: Browse, sort: SortSpec, limit: Int, offset: Int, sources: List<String>, restricted: Set<String>, after: PageAfter? = null): List<Series> =
        pageRows(ContentKind.SERIES, browse, sort, limit, offset, sources, restricted, after) { q -> db.browse().seriesOnce(q).map { it.toModel() } }

    /** The index that serves this order over the whole library, or null (a folder, a filter, favourites first, a descending name, a rating: those keep their own queries). */
    fun indexPlanFor(kind: ContentKind, browse: Browse, sort: SortSpec): IndexPlan? {
        if (kind == ContentKind.CHANNEL || browse != Browse.All || sort.favoritesFirst || sort.unwatchedFirst) return null
        return when { sort.field == SortField.NAME && sort.ascending -> IndexPlan.NAME_ASC; sort.field == SortField.YEAR && sort.ascending -> IndexPlan.YEAR_DESC; else -> null }
    }

    /** True when every row has its lower-case title (the triggers and the 11 to 12 step guarantee it; a database made some other way is read the old way). */
    private suspend fun sortReady(table: String): Boolean = db.openHelper.readableDatabase.query("SELECT 1 FROM $table WHERE titleSort = '' AND title <> '' LIMIT 1").use { !it.moveToFirst() }

    private suspend fun <T> pageRows(kind: ContentKind, browse: Browse, sort: SortSpec, limit: Int, offset: Int, sources: List<String>, restricted: Set<String>, after: PageAfter?, read: suspend (androidx.sqlite.db.SupportSQLiteQuery) -> List<T>): List<T> {
        val fav = db.browse().favoriteFoldersNow(kind.name)
        val plan = indexPlanFor(kind, browse, sort)?.takeIf { sortReady(if (kind == ContentKind.MOVIE) "movies" else "series") }
        if (plan == null) return read(build(kind, browse, sort, limit, sources, restricted, fav, false, offset))
        if (plan == IndexPlan.YEAR_DESC && after != null && after.year == null) return read(build(kind, browse, sort, limit, sources, restricted, fav, false, 0, IndexPlan.YEAR_NULLS, after))
        val rows = read(build(kind, browse, sort, limit, sources, restricted, fav, false, if (after == null) offset else 0, plan, after))
        // Newest year first: the titles with no year follow the dated ones; when a page ends inside the dated ones the rest of the page is filled from them.
        if (plan == IndexPlan.YEAR_DESC && after?.year != null && rows.size < limit) return rows + read(build(kind, browse, sort, limit - rows.size, sources, restricted, fav, false, 0, IndexPlan.YEAR_NULLS, null))
        return rows
    }

    fun movies(browse: Browse, sort: SortSpec, limit: Int = 600, offset: Int = 0): Flow<List<Movie>> = query(ContentKind.MOVIE, browse, sort, limit, offset = offset) { (if (orderMoves(browse, sort)) db.browse().movies(it) else db.browse().moviesPlain(it)).map { l -> l.map { e -> e.toModel() } } }
    fun series(browse: Browse, sort: SortSpec, limit: Int = 600, offset: Int = 0): Flow<List<Series>> = query(ContentKind.SERIES, browse, sort, limit, offset = offset) { (if (orderMoves(browse, sort)) db.browse().series(it) else db.browse().seriesPlain(it)).map { l -> l.map { e -> e.toModel() } } }
    fun channels(browse: Browse, sort: SortSpec, limit: Int = 40000): Flow<List<Channel>> = query(ContentKind.CHANNEL, browse, sort, limit) { db.browse().channels(it).map { l -> l.map { e -> e.toModel() } } }

    /** One page of channels from [offset] on, read once (not watched): the next rows of the list the screen already shows. */
    suspend fun channelPage(browse: Browse, sort: SortSpec, limit: Int, offset: Int): List<Channel> =
        query(ContentKind.CHANNEL, browse, sort, limit, offset = offset) { db.browse().channels(it).map { l -> l.map { e -> e.toModel() } } }.first()

    /** How many channels the same shortcut or folder holds in all (counted by the database, kept apart from the rows that are loaded). */
    fun channelCount(browse: Browse): Flow<Int> = query(ContentKind.CHANNEL, browse, SortSpec.defaultFor(ContentKind.CHANNEL), -1, wrap = true) { db.browse().channelCount(it) }

    private fun <T> query(kind: ContentKind, browse: Browse, sort: SortSpec, limit: Int, wrap: Boolean = false, offset: Int = 0, run: (androidx.sqlite.db.SupportSQLiteQuery) -> Flow<T>): Flow<T> =
        combine(library.sourceIds, folders.restrictedIds(kind), db.browse().favoriteFolders(kind.name)) { ids, locked, favFolders -> Triple(ids, locked, favFolders) }
            .flatMapLatest { (ids, locked, favFolders) -> run(build(kind, browse, sort, limit, ids, locked, favFolders, wrap, offset)) }

    private fun build(kind: ContentKind, browse: Browse, sort: SortSpec, limit: Int, sources: List<String>, locked: Set<String>, favFolders: List<String>, count: Boolean = false, offset: Int = 0, plan: IndexPlan? = null, after: PageAfter? = null): SimpleSQLiteQuery {
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
            is Browse.Collection -> { where += "EXISTS (SELECT 1 FROM collection_items ci WHERE ci.itemId = x.id AND ci.collectionId = ?)"; args += browse.id }
            is Browse.Smart -> {
                val unwatched = if (kind == ContentKind.SERIES) "NOT EXISTS (SELECT 1 FROM progress p WHERE p.seriesId = x.id)" else "NOT EXISTS (SELECT 1 FROM progress p WHERE p.itemId = x.id)"
                where += when (browse.rule) {
                    SmartRule.UNWATCHED -> unwatched
                    SmartRule.UNWATCHED_FAVORITES -> "$unwatched AND ${inList(UserRepository.FAVOURITES)}"
                    SmartRule.NEW_30D -> "${CollectionRuleSql.ADDED_AT_SECONDS} >= CAST(strftime('%s','now','-30 days') AS INTEGER)"
                }
            }
            is Browse.Rule -> { val q = CollectionRuleSql.of(kind, browse.rule); where.addAll(q.conditions); args.addAll(q.args) }
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
            SortField.ADDED -> if (kind == ContentKind.CHANNEL) "x.addedAt ${dir("DESC")}, x.rowid ${dir("ASC")}"      // channels with no date keep the provider's order
                else if (kind == ContentKind.SERIES) "x.rowid ${dir("DESC")}"                                         // series: the order they appeared in the catalog, the later the newer
                else "x.addedAt ${dir("DESC")}, x.rowid ${dir("DESC")}"                                           // a provider that sends no dates: the later in its list, the newer
            SortField.UPDATED -> if (kind == ContentKind.SERIES) "x.addedAt ${dir("DESC")}, x.rowid ${dir("DESC")}" else "x.rowid ASC"     // the provider's own "last modified" time
            SortField.NEW_EPISODES -> if (kind == ContentKind.SERIES) "(NOT EXISTS (SELECT 1 FROM new_episodes ne WHERE ne.seriesId = x.id)) ${dir("ASC")}, x.addedAt DESC" else "x.rowid ASC"
            SortField.RECENTLY_WATCHED -> { joins.append(" LEFT JOIN (SELECT itemId, MAX(playedAt) AS lastPlayed FROM watch_log GROUP BY itemId) w ON w.itemId = x.id"); "(w.lastPlayed IS NULL) ASC, w.lastPlayed ${dir("DESC")}" }
            SortField.YEAR -> if (kind == ContentKind.CHANNEL) "x.rowid ASC" else "(x.year IS NULL) ASC, x.year ${dir("DESC")}"
            SortField.RATING -> if (kind == ContentKind.CHANNEL) "x.rowid ASC" else "(x.rating IS NULL OR x.rating = '' OR CAST(x.rating AS REAL) = 0) ASC, CAST(x.rating AS REAL) ${dir("DESC")}"
            SortField.DURATION -> "x.rowid ASC"
        }
        order += primary; order += "x.id ASC"
        var from = "$table x"
        if (plan != null && !count) {
            // Read from the index, in its own order, from where the last page ended. (The planner would otherwise prefer the source index and sort every row.)
            order.clear()
            when (plan) {
                IndexPlan.NAME_ASC -> {
                    from = "$table x INDEXED BY index_${table}_titleSort_id"
                    if (after != null) { val k = app.streamsetu.core.model.SortKey.of(after.title); where += "x.titleSort >= ? AND (x.titleSort > ? OR x.id > ?)"; args += k; args += k; args += after.id }
                    order += "x.titleSort ASC"; order += "x.id ASC"
                }
                IndexPlan.YEAR_DESC -> {
                    from = "$table x INDEXED BY index_${table}_year_id"
                    val y = after?.year
                    if (after != null && y != null) { where += "x.year <= ? AND (x.year < ? OR x.id > ?)"; args += y; args += y; args += after.id }
                    order += "x.year DESC"; order += "x.id ASC"
                }
                IndexPlan.YEAR_NULLS -> {
                    from = "$table x INDEXED BY index_${table}_year_id"
                    where += "x.year IS NULL"
                    if (after != null && after.year == null) { where += "x.id > ?"; args += after.id }
                    order += "x.year DESC"; order += "x.id ASC"
                }
            }
        }
        val sql = if (count) "SELECT COUNT(*) FROM $table x$joins WHERE ${where.joinToString(" AND ")}"
            else "SELECT x.* FROM $from$joins WHERE ${where.joinToString(" AND ")} ORDER BY ${order.joinToString(", ")} LIMIT $limit OFFSET $offset"
        return SimpleSQLiteQuery(sql, args.toTypedArray())
    }
}

/**
 * True for an order or a shortcut whose members move when the person favourites, watches or changes something (favourites first, unwatched first, recently watched, new episodes,
 * and the person's own lists). Pages loaded earlier cannot be trusted after such a change, so a list in one of these starts again from its first page.
 */
fun orderMoves(b: Browse, s: SortSpec) = s.favoritesFirst || s.unwatchedFirst || s.field == SortField.RECENTLY_WATCHED || s.field == SortField.NEW_EPISODES ||
    b is Browse.Favorites || b is Browse.WatchLater || b is Browse.Recent || b is Browse.Continue || b is Browse.FavoriteFolders || b is Browse.Collection || b is Browse.Smart || b is Browse.Rule
