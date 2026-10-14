package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map

/** Everything the screens read: categories, channels, movies, series, episodes and search. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CatalogRepository(private val db: AppDatabase, private val library: LibraryRepository) {
    private val dao get() = db.catalog()
    private val ids get() = library.sourceIds.value
    private fun <T> scoped(block: (List<String>) -> Flow<T>): Flow<T> = library.sourceIds.flatMapLatest(block)

    fun categories(kind: ContentKind): Flow<List<Category>> = scoped { s -> dao.categories(kind.name, s).map { l -> l.map { it.toModel() } } }
    fun channels(categoryId: String): Flow<List<Channel>> = dao.channelsIn(categoryId).map { l -> l.map { it.toModel() } }
    fun allChannels(limit: Int = 2000): Flow<List<Channel>> = scoped { s -> dao.allChannels(limit, s).map { l -> l.map { it.toModel() } } }
    fun movies(categoryId: String, limit: Int = 300): Flow<List<Movie>> = dao.moviesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun latestMovies(limit: Int = 40): Flow<List<Movie>> = scoped { s -> dao.latestMovies(limit, s).map { l -> l.map { it.toModel() } } }
    fun allMovies(limit: Int = 600): Flow<List<Movie>> = scoped { s -> dao.allMovies(limit, s).map { l -> l.map { it.toModel() } } }
    suspend fun moviesByIds(ids: List<String>): List<Movie> = if (ids.isEmpty()) emptyList() else dao.moviesByIds(ids).map { it.toModel() }
    suspend fun seriesByIds(ids: List<String>): List<Series> = if (ids.isEmpty()) emptyList() else dao.seriesByIds(ids).map { it.toModel() }
    fun seriesIn(categoryId: String, limit: Int = 300): Flow<List<Series>> = dao.seriesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun allSeries(limit: Int = 40): Flow<List<Series>> = scoped { s -> dao.allSeries(limit, s).map { l -> l.map { it.toModel() } } }
    fun latestSeries(limit: Int = 40): Flow<List<Series>> = scoped { s -> dao.latestSeries(limit, s).map { l -> l.map { it.toModel() } } }
    fun episodes(seriesId: String): Flow<List<Episode>> = dao.episodes(seriesId).map { l -> l.map { it.toModel() } }

    suspend fun channel(id: String) = dao.channel(id)?.toModel()
    suspend fun movie(id: String) = dao.movie(id)?.toModel()
    suspend fun series(id: String) = dao.series(id)?.toModel()
    suspend fun episode(id: String) = dao.episode(id)?.toModel()

    /** The episode after [episode] in the same series (the next one in the season, or the first of the next season). */
    suspend fun episodesOnce(seriesId: String): List<Episode> = dao.episodesOnce(seriesId).map { it.toModel() }

    suspend fun nextEpisode(episode: Episode): Episode? {
        val all = dao.episodesOnce(episode.seriesId).map { it.toModel() }
        val i = all.indexOfFirst { it.id == episode.id }
        return if (i >= 0) all.getOrNull(i + 1) else null
    }

    /** A fresh mix of movies and series with artwork, for the banner on Home. Different every time the app opens. */
    suspend fun featured(count: Int = 6): List<Playable> {
        val m = dao.randomMovies(count, ids).map { MoviePlayable(it.toModel()) as Playable }
        val s = dao.randomSeries(count, ids).map { SeriesFeature(it.toModel()) as Playable }
        return (m + s).shuffled().take(count)
    }

    suspend fun search(query: String, limit: Int = 30): SearchResults {
        val q = query.trim()
        if (q.length < 2) return SearchResults()
        return SearchResults(
            channels = dao.searchChannels(q, limit, ids).map { it.toModel() },
            movies = dao.searchMovies(q, limit, ids).map { it.toModel() },
            series = dao.searchSeries(q, limit, ids).map { it.toModel() },
        )
    }
}

data class SearchResults(val channels: List<Channel> = emptyList(), val movies: List<Movie> = emptyList(), val series: List<Series> = emptyList()) {
    val isEmpty get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}
