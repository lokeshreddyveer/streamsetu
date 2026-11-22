package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.CandidateRow
import app.streamsetu.core.data.repo.smartmix.CanonicalPick
import app.streamsetu.core.data.repo.smartmix.Derive
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.core.data.repo.smartmix.PreferredSource
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map

/** Everything the screens read: categories, channels, movies, series, episodes and search. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
/** Ids per query: under SQLite's limit of 999 variables on Android 5 to 7. */
private const val ID_CHUNK = 500
/** How many of the newest titles of each kind the banner mix is drawn from. */
private const val FEATURED_POOL = 1500

class CatalogRepository(private val db: AppDatabase, private val library: LibraryRepository, private val folders: FolderRepository) {
    private val dao get() = db.catalog()
    private val ids get() = library.sourceIds.value
    private fun <T> scoped(block: (List<String>) -> Flow<T>): Flow<T> = library.sourceIds.flatMapLatest(block)

    fun categories(kind: ContentKind): Flow<List<Category>> = scoped { s -> dao.categories(kind.name, s).map { l -> l.map { it.toModel() } } }
    fun channels(categoryId: String): Flow<List<Channel>> = dao.channelsIn(categoryId).map { l -> l.map { it.toModel() } }
    fun allChannels(limit: Int = 2000): Flow<List<Channel>> = scoped { s -> dao.allChannels(limit, s).map { l -> l.map { it.toModel() } } }
    fun movies(categoryId: String, limit: Int = 300): Flow<List<Movie>> = dao.moviesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun latestMovies(limit: Int = 40): Flow<List<Movie>> = scoped { s -> dao.latestMovies(limit, s).map { l -> l.map { it.toModel() } } }
    fun allMovies(limit: Int = 600): Flow<List<Movie>> = scoped { s -> dao.allMovies(limit, s).map { l -> l.map { it.toModel() } } }
    suspend fun moviesByIds(ids: List<String>): List<Movie> = ids.chunked(ID_CHUNK).flatMap { dao.moviesByIds(it) }.map { it.toModel() }          // in groups: SQLite on Android 5 to 7 allows 999 variables in one query, and a long favourites list used to crash Home
    suspend fun seriesByIds(ids: List<String>): List<Series> = ids.chunked(ID_CHUNK).flatMap { dao.seriesByIds(it) }.map { it.toModel() }
    fun seriesIn(categoryId: String, limit: Int = 300): Flow<List<Series>> = dao.seriesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun allSeries(limit: Int = 40): Flow<List<Series>> = scoped { s -> dao.allSeries(limit, s).map { l -> l.map { it.toModel() } } }
    fun latestSeries(limit: Int = 40): Flow<List<Series>> = scoped { s -> dao.latestSeries(limit, s).map { l -> l.map { it.toModel() } } }
    fun episodes(seriesId: String): Flow<List<Episode>> = dao.episodes(seriesId).map { l -> l.map { it.toModel() } }

    suspend fun channel(id: String) = dao.channel(id)?.toModel()
    /** The same channel in the person's other enabled connections, best match first. */
    suspend fun channelCopiesElsewhere(c: Channel): List<Channel> = dao.channelCopiesElsewhere(c.sourceId, c.name, c.epgId.orEmpty()).map { it.toModel() }
    suspend fun movie(id: String) = dao.movie(id)?.toModel()
    suspend fun series(id: String) = dao.series(id)?.toModel()
    suspend fun episode(id: String) = dao.episode(id)?.toModel()
    /** Several episodes in one read (never one read per title). */
    suspend fun episodesByIds(ids: List<String>): Map<String, Episode> = ids.chunked(ID_CHUNK).flatMap { dao.episodesByIds(it) }.associate { it.id to it.toModel() }

    /** The episode after [episode] in the same series (the next one in the season, or the first of the next season). */
    suspend fun episodesOnce(seriesId: String): List<Episode> = dao.episodesOnce(seriesId).map { it.toModel() }

    suspend fun nextEpisode(episode: Episode): Episode? {
        val all = dao.episodesOnce(episode.seriesId).map { it.toModel() }
        val i = all.indexOfFirst { it.id == episode.id }
        return if (i >= 0) all.getOrNull(i + 1) else null
    }

    /**
     * A fresh mix of movies and series with artwork, for the banner on Home. Different every time the app opens: drawn at random from the newest titles with a picture (a bounded pool
     * read from the index, not a random sort of the whole library), one card for each title however many copies there are. A banner is a recommendation, so it follows the strictest rule:
     * nothing from a locked, hidden or adult-blocked folder, and no title that has a copy in one (another language, another playlist), whether or not the folder is unlocked at the moment.
     */
    suspend fun featured(count: Int = 6, pool: Int = FEATURED_POOL): List<Playable> {
        val snap = folders.visibility.snapshot(Visibility.Surface.RECOMMEND)
        val rank = PreferredSource.rank(db.sources().all().map { PreferredSource.Info(it.id, it.enabled, it.draft, it.status == "FAILED", it.lastSyncAt, it.sortOrder) })
        fun pick(kind: ContentKind, rows: List<CandidateRow>): List<String> {
            val copies = rows.filter { snap.titleOk(kind, it.categoryId, it.title, it.year) }.map { r ->
                CanonicalPick.Copy(r.id, kind.name, r.sourceId, r.categoryId, IdentityKey.ofOrFallback(r.title), IdentityKey.yearOf(r.title, r.year), Derive.languageOf(r.title, null), Derive.qualityRank(r.title, null), r.addedAt)
            }
            return CanonicalPick.group(copies, CanonicalPick.Context(sourceRank = rank)).filter { !it.restricted }.map { it.canonical.itemId }.shuffled().take(count)
        }
        val movieRows = ids.flatMap { dao.recentMovieCandidates(it, pool) }.sortedByDescending { it.addedAt }.take(pool)
        val seriesRows = ids.flatMap { dao.recentSeriesCandidates(it, pool) }.sortedByDescending { it.addedAt }.take(pool)
        val m = dao.moviesByIds(pick(ContentKind.MOVIE, movieRows)).map { MoviePlayable(it.toModel()) as Playable }
        val s = dao.seriesByIds(pick(ContentKind.SERIES, seriesRows)).map { SeriesFeature(it.toModel()) as Playable }
        return (m + s).shuffled().take(count)
    }

    /**
     * What a shared link by name opens: the first title with that name. If it sits in a locked folder (not unlocked), nothing plays and the folder is named so the app can ask for the
     * PIN; if it is hidden or adult-blocked, nothing opens. A link never reaches a title the person could not open by hand.
     */
    suspend fun linkTarget(kind: String?, query: String): LinkTarget {
        val q = query.trim()
        if (q.length < 2) return LinkTarget.None
        val v = folders.visibility
        val k = when (kind) { "movie" -> ContentKind.MOVIE; "series" -> ContentKind.SERIES; else -> ContentKind.CHANNEL }
        val out = v.excludedFolders(k, Visibility.Surface.SEARCH)
        val lockedNow = folders.lockedIdsNow()
        fun check(folder: String?, open: () -> LinkTarget): LinkTarget = when {
            folder == null || folder !in out -> open()
            folder in lockedNow -> LinkTarget.Locked(k, folder)
            else -> LinkTarget.None
        }
        return when (k) {
            ContentKind.MOVIE -> dao.searchMovies(q, 1, ids).firstOrNull()?.let { m -> check(m.categoryId) { LinkTarget.Movie(m.toModel()) } }
            ContentKind.SERIES -> dao.searchSeries(q, 1, ids).firstOrNull()?.let { s -> check(s.categoryId) { LinkTarget.Series(s.toModel()) } }
            else -> dao.searchChannels(q, 1, ids).firstOrNull()?.let { c -> check(c.categoryId) { LinkTarget.Channel(c.toModel()) } }
        } ?: LinkTarget.None
    }

    /** The first matches by name (a shared link names a title this way). Folders that are locked, hidden or adult-blocked for this profile are never searched. */
    suspend fun search(query: String, limit: Int = 30): SearchResults {
        val q = query.trim()
        if (q.length < 2) return SearchResults()
        val v = folders.visibility
        val skip = ContentKind.values().filter { it == ContentKind.CHANNEL || it == ContentKind.MOVIE || it == ContentKind.SERIES }.associateWith { v.excludedFolders(it, Visibility.Surface.SEARCH) }
        fun ok(kind: ContentKind, folder: String?) = folder == null || folder !in skip.getValue(kind)
        val room = limit * 4          // the names are matched in the database, the folder rule here: ask for more so a few restricted ones do not empty the list
        return SearchResults(
            channels = dao.searchChannels(q, room, ids).filter { ok(ContentKind.CHANNEL, it.categoryId) }.take(limit).map { it.toModel() },
            movies = dao.searchMovies(q, room, ids).filter { ok(ContentKind.MOVIE, it.categoryId) }.take(limit).map { it.toModel() },
            series = dao.searchSeries(q, room, ids).filter { ok(ContentKind.SERIES, it.categoryId) }.take(limit).map { it.toModel() },
        )
    }
}

/** What a shared link by name points at (`?movie=`, `?series=`, `?channel=`). */
sealed interface LinkTarget {
    data class Movie(val movie: app.streamsetu.core.model.Movie) : LinkTarget
    data class Series(val series: app.streamsetu.core.model.Series) : LinkTarget
    data class Channel(val channel: app.streamsetu.core.model.Channel) : LinkTarget
    /** The title is in a locked folder: nothing plays; the caller opens that folder, which asks for the PIN. */
    data class Locked(val kind: ContentKind, val folderId: String) : LinkTarget
    /** Nothing found, or the title is hidden or adult-blocked for this profile. */
    data object None : LinkTarget
}

data class SearchResults(val channels: List<Channel> = emptyList(), val movies: List<Movie> = emptyList(), val series: List<Series> = emptyList()) {
    val isEmpty get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}
