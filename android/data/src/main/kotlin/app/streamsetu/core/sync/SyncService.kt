package app.streamsetu.core.sync

import androidx.room.withTransaction
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.toEntity
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.*
import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull

/** Reads a playlist into the database. Old rows of that playlist are replaced only after the new ones were read successfully. */
class SyncService(private val db: AppDatabase, private val sources: SourceRepository, private val credentials: CredentialStore, private val resolver: app.streamsetu.core.net.StreamResolver? = null, private val openLocal: (String) -> java.io.InputStream = { error("This device cannot open local files.") }) {

    data class Result(val channels: Int, val movies: Int, val series: Int)

    suspend fun sync(sourceId: String): Result = withContext(Dispatchers.IO) {
        val source = sources.get(sourceId) ?: error("That playlist no longer exists.")
        sources.setStatus(sourceId, SyncStatus.SYNCING, source.lastSyncAt)
        try {
            val r = when (source.type) {
                SourceType.M3U, SourceType.LOCAL_FILE -> syncM3u(source)
                SourceType.XTREAM -> syncXtream(source)
            }
            sources.setStatus(sourceId, SyncStatus.OK)
            sources.setCounts(sourceId, r.channels, r.movies, r.series)
            r
        } catch (e: Throwable) {
            sources.setStatus(sourceId, SyncStatus.FAILED, source.lastSyncAt)
            sources.setError(sourceId, e.message?.take(200))
            throw e
        }
    }

    // ---- M3U -------------------------------------------------------------------------------------------------

    private suspend fun syncM3u(s: Source): Result {
        val categories = LinkedHashMap<String, CategoryEntity>()
        val channels = ArrayList<ChannelEntity>(); val movies = ArrayList<MovieEntity>()
        var order = 0
        fun category(name: String?, kind: ContentKind): String? {
            val n = name ?: return null
            val id = "${s.id}:${kind.name}:$n"
            categories.getOrPut(id) { CategoryEntity(id, s.id, kind.name, n, categories.size) }
            return id
        }
        var guideUrl: String? = null
        val read: (kotlin.sequences.Sequence<String>) -> Unit = { lines ->
            M3uParser.parse(lines, onHeader = { guideUrl = it }) { e ->
                    order++
                    when (e.kind) {
                        ContentKind.CHANNEL -> if (!ChannelFilter.isDivider(e.name)) channels += ChannelEntity(
                            id = "${s.id}:ch:${stableId(e)}", sourceId = s.id, categoryId = category(e.group ?: "Other", ContentKind.CHANNEL), name = e.name,
                            number = e.channelNumber, logoUrl = e.logo, streamRef = e.url, epgId = e.tvgId ?: e.tvgName, catchupDays = e.catchupDays, sortOrder = order,
                        )
                        ContentKind.MOVIE -> movies += MovieEntity(
                            id = "${s.id}:mv:${stableId(e)}", sourceId = s.id, categoryId = category(e.group ?: "Movies", ContentKind.MOVIE), title = e.name,
                            posterUrl = e.logo, year = null, rating = null, plot = null, streamRef = e.url, addedAt = order.toLong(),
                        )
                        else -> {}      // series episodes inside an M3U are not grouped into series
                    }
                }
        }
        if (s.type == SourceType.LOCAL_FILE) openLocal(s.address).bufferedReader().useLines { read(it) }
        else Http.get(s.address) { resp -> resp.body!!.charStream().buffered().useLines { read(it) } }
        if (channels.isEmpty() && movies.isEmpty()) error("That playlist has no channels or movies.")
        replace(s.id, categories.values.toList(), channels, movies, emptyList())
        if (s.epgUrl == null && guideUrl != null) db.sources().upsert(s.copy(epgUrl = guideUrl).toEntity())
        return Result(channels.size, movies.size, 0)
    }

    private fun stableId(e: M3uEntry) = (e.tvgId ?: "") + "|" + e.name + "|" + e.url.hashCode()

    // ---- Xtream ----------------------------------------------------------------------------------------------

    private suspend fun syncXtream(s: Source): Result {
        val user = s.username.orEmpty()
        val pass = credentials.load(SourceRepository.credentialRef(s.id)).orEmpty()
        val host = s.address
        fun fetch(action: String) = Xtream.parseArray(Http.text(Xtream.api(host, user, pass, action)))

        val auth = Xtream.parseObject(Http.text(Xtream.api(host, user, pass)))
        val info = auth?.get("user_info") as? JsonObject
        if (info == null || info.int("auth") == 0) error("The server refused the login. Check the user name and password.")
        info.str("max_connections")?.toIntOrNull()?.let { resolver?.rememberMaxConnections(s.id, it) }
        resolver?.remember(s.id, (info["allowed_output_formats"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull }.orEmpty())

        val categories = ArrayList<CategoryEntity>()
        fun cats(action: String, kind: ContentKind) = fetch(action).forEachIndexed { i, o ->
            val id = o.str("category_id") ?: return@forEachIndexed
            categories += CategoryEntity("${s.id}:${kind.name}:$id", s.id, kind.name, o.str("category_name") ?: "Category $id", i)
        }
        cats("get_live_categories", ContentKind.CHANNEL); cats("get_vod_categories", ContentKind.MOVIE); cats("get_series_categories", ContentKind.SERIES)

        val channels = fetch("get_live_streams").mapIndexedNotNull { i, o ->
            val id = o.str("stream_id") ?: return@mapIndexedNotNull null
            if (ChannelFilter.isDivider(o.str("name").orEmpty())) return@mapIndexedNotNull null
            ChannelEntity("${s.id}:ch:$id", s.id, o.str("category_id")?.let { "${s.id}:CHANNEL:$it" }, o.str("name") ?: "Channel $id", o.int("num"),
                o.str("stream_icon"), "live:$id:m3u8", o.str("epg_channel_id"), o.int("tv_archive_duration") ?: 0, i, o.str("added")?.toLongOrNull() ?: 0)
        }
        val movies = fetch("get_vod_streams").mapNotNull { o ->
            val id = o.str("stream_id") ?: return@mapNotNull null
            MovieEntity("${s.id}:mv:$id", s.id, o.str("category_id")?.let { "${s.id}:MOVIE:$it" }, o.str("name") ?: "Movie $id", o.str("stream_icon"),
                year(o.str("year") ?: o.str("releaseDate")), o.str("rating"), null, "movie:$id:${o.str("container_extension") ?: "mp4"}", o.str("added")?.toLongOrNull() ?: 0)
        }
        val series = fetch("get_series").mapNotNull { o ->
            val id = o.str("series_id") ?: return@mapNotNull null
            SeriesEntity("${s.id}:sr:$id", s.id, o.str("category_id")?.let { "${s.id}:SERIES:$it" }, o.str("name") ?: "Series $id", o.str("cover"),
                (o["backdrop_path"] as? kotlinx.serialization.json.JsonArray)?.firstOrNull()?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content },
                year(o.str("year") ?: o.str("releaseDate")), o.str("rating"), o.str("plot"), id, o.str("last_modified")?.toLongOrNull() ?: 0)
        }
        replace(s.id, categories, channels, movies, series)
        return Result(channels.size, movies.size, series.size)
    }

    /** A series' episodes are read when the person opens it. */
    suspend fun loadEpisodes(series: Series): Int = withContext(Dispatchers.IO) {
        val src = sources.get(series.sourceId) ?: return@withContext 0
        if (src.type != SourceType.XTREAM) return@withContext 0
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val obj = Xtream.parseObject(Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_series_info", "&series_id=${series.providerId}"))) ?: return@withContext 0
        val seasons = obj["episodes"] as? JsonObject ?: return@withContext 0
        val out = ArrayList<EpisodeEntity>()
        for ((seasonKey, list) in seasons) {
            val arr = list as? kotlinx.serialization.json.JsonArray ?: continue
            for (el in arr) {
                val e = el as? JsonObject ?: continue
                val id = e.str("id") ?: continue
                val info = e["info"] as? JsonObject
                out += EpisodeEntity("${series.sourceId}:ep:$id", series.id, e.int("season") ?: seasonKey.toIntOrNull() ?: 1, e.int("episode_num") ?: 0,
                    e.str("title") ?: "Episode ${e.str("episode_num")}", info?.str("plot"), info?.str("movie_image"), info?.int("duration_secs"),
                    "series:$id:${e.str("container_extension") ?: "mp4"}")
            }
        }
        val known = db.extras().episodeIds(series.id).toSet()
        db.catalog().putEpisodes(out)
        // An episode that shows up after the series was already read, in a series the person has watched, is flagged as new.
        if (known.isNotEmpty() && series.id in db.extras().seriesWithProgress()) {
            val fresh = out.filter { it.id !in known }
            if (fresh.isNotEmpty()) db.extras().putNewEpisodes(fresh.map { app.streamsetu.core.data.db.NewEpisodeEntity(it.id, series.id, System.currentTimeMillis()) })
        }
        out.size
    }

    data class MovieInfo(val plot: String?, val cast: String?, val director: String?, val genre: String?, val duration: String?, val backdrop: String?, val releaseDate: String?)
    private val movieInfoCache = java.util.concurrent.ConcurrentHashMap<String, MovieInfo>()

    /** A movie's story, cast and so on, from the provider (`get_vod_info`). Remembered for the session. */
    suspend fun movieInfo(movie: app.streamsetu.core.model.Movie): MovieInfo? = withContext(Dispatchers.IO) {
        movieInfoCache[movie.id]?.let { return@withContext it }
        val src = sources.get(movie.sourceId) ?: return@withContext null
        if (src.type != SourceType.XTREAM) return@withContext null
        val vodId = movie.streamRef.split(':').getOrNull(1) ?: return@withContext null
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val obj = runCatching { Xtream.parseObject(Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_vod_info", "&vod_id=$vodId"))) }.getOrNull() ?: return@withContext null
        val info = obj["info"] as? JsonObject ?: return@withContext null
        val backdrop = ((info["backdrop_path"] as? kotlinx.serialization.json.JsonArray)?.firstOrNull() as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
        MovieInfo(info.str("plot") ?: info.str("description"), info.str("cast") ?: info.str("actors"), info.str("director"), info.str("genre"),
            info.str("duration"), backdrop, info.str("releasedate") ?: info.str("release_date")).also { movieInfoCache[movie.id] = it }
    }

    /** Reads the episode lists of series the person has started, one at a time and slowly, to notice new episodes. Never runs while something plays. */
    suspend fun refreshWatchedSeries(limit: Int = 25, shouldStop: () -> Boolean = { false }): Int {
        var found = 0
        for (id in db.extras().seriesWithProgress().take(limit)) {
            if (shouldStop()) break
            val entity = db.catalog().series(id) ?: continue
            val before = db.extras().episodeIds(id).size
            runCatching { loadEpisodes(entity.toModel()) }
            found += (db.extras().episodeIds(id).size - before).coerceAtLeast(0)
            kotlinx.coroutines.delay(400)
        }
        return found
    }

    private fun year(s: String?) = s?.take(4)?.toIntOrNull()

    private suspend fun replace(sourceId: String, cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>) {
        db.withTransaction {
            val c = db.catalog()
            c.clearCategories(sourceId); c.clearChannels(sourceId); c.clearMovies(sourceId); c.clearSeries(sourceId)
            cats.chunked(500).forEach { c.putCategories(it) }
            ch.chunked(500).forEach { c.putChannels(it) }
            mv.chunked(500).forEach { c.putMovies(it) }
            sr.chunked(500).forEach { c.putSeries(it) }
            // The text index changes in the same transaction, so a refresh that fails keeps the old catalog and the old index together.
            val raw = db.openHelper.writableDatabase
            app.streamsetu.core.data.db.SearchIndex.clear(raw, sourceId)
            val hits = ArrayList<app.streamsetu.core.data.db.SearchHit>(ch.size + mv.size + sr.size)
            ch.forEach { hits += app.streamsetu.core.data.db.SearchHit("CHANNEL", it.id, sourceId, it.categoryId, it.name) }
            mv.forEach { hits += app.streamsetu.core.data.db.SearchHit("MOVIE", it.id, sourceId, it.categoryId, it.title) }
            sr.forEach { hits += app.streamsetu.core.data.db.SearchHit("SERIES", it.id, sourceId, it.categoryId, it.title) }
            hits.chunked(2000).forEach { app.streamsetu.core.data.db.SearchIndex.insert(raw, it) }
        }
    }
}

/** Providers put divider rows in the channel list ("####### Bulgaria #######", "=== SPORTS ==="). They are not streams. */
object ChannelFilter {
    fun isDivider(name: String): Boolean {
        val letters = name.count { it.isLetterOrDigit() }
        val marks = name.count { it == '#' || it == '=' || it == '*' || it == '_' || it == '-' || it == '~' || it == '•' }
        return name.isBlank() || (marks >= 4 && marks >= letters / 2)
    }
}
