package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Everything the screens read: categories, channels, movies, series, episodes and search. */
class CatalogRepository(private val db: AppDatabase) {
    private val dao get() = db.catalog()

    fun categories(kind: ContentKind): Flow<List<Category>> = dao.categories(kind.name).map { l -> l.map { it.toModel() } }
    fun channels(categoryId: String): Flow<List<Channel>> = dao.channelsIn(categoryId).map { l -> l.map { it.toModel() } }
    fun allChannels(limit: Int = 2000): Flow<List<Channel>> = dao.allChannels(limit).map { l -> l.map { it.toModel() } }
    fun movies(categoryId: String, limit: Int = 300): Flow<List<Movie>> = dao.moviesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun latestMovies(limit: Int = 40): Flow<List<Movie>> = dao.latestMovies(limit).map { l -> l.map { it.toModel() } }
    fun seriesIn(categoryId: String, limit: Int = 300): Flow<List<Series>> = dao.seriesIn(categoryId, limit).map { l -> l.map { it.toModel() } }
    fun allSeries(limit: Int = 40): Flow<List<Series>> = dao.allSeries(limit).map { l -> l.map { it.toModel() } }
    fun episodes(seriesId: String): Flow<List<Episode>> = dao.episodes(seriesId).map { l -> l.map { it.toModel() } }

    suspend fun channel(id: String) = dao.channel(id)?.toModel()
    suspend fun movie(id: String) = dao.movie(id)?.toModel()
    suspend fun series(id: String) = dao.series(id)?.toModel()
    suspend fun episode(id: String) = dao.episode(id)?.toModel()

    /** The episode after [episode] in the same series (the next one in the season, or the first of the next season). */
    suspend fun nextEpisode(episode: Episode): Episode? {
        val all = dao.episodesOnce(episode.seriesId).map { it.toModel() }
        val i = all.indexOfFirst { it.id == episode.id }
        return if (i >= 0) all.getOrNull(i + 1) else null
    }

    suspend fun search(query: String, limit: Int = 30): SearchResults {
        val q = query.trim()
        if (q.length < 2) return SearchResults()
        return SearchResults(
            channels = dao.searchChannels(q, limit).map { it.toModel() },
            movies = dao.searchMovies(q, limit).map { it.toModel() },
            series = dao.searchSeries(q, limit).map { it.toModel() },
        )
    }
}

data class SearchResults(val channels: List<Channel> = emptyList(), val movies: List<Movie> = emptyList(), val series: List<Series> = emptyList()) {
    val isEmpty get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}
