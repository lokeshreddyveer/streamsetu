package app.streamsetu.core.sync

import androidx.room.withTransaction
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.toEntity
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.net.*
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.*
import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull

/** Reads a playlist into the database. Old rows of that playlist are replaced only after the new ones were read successfully. */
class SyncService(private val db: AppDatabase, private val sources: SourceRepository, private val credentials: CredentialStore, private val resolver: app.streamsetu.core.net.StreamResolver? = null, private val openLocal: (String) -> java.io.InputStream = { error("This device cannot open local files.") }, private val listFolder: (String) -> List<FoundVideo> = { error("This device cannot read folders.") }) {
    private val sessions = MediaSessions(credentials)
    private val plex = PlexClient()
    private val dav = WebDavClient()

    data class Result(val channels: Int, val movies: Int, val series: Int)

    suspend fun sync(sourceId: String): Result = withContext(Dispatchers.IO) {
        val source = sources.get(sourceId) ?: error("That playlist no longer exists.")
        sources.setStatus(sourceId, SyncStatus.SYNCING, source.lastSyncAt)
        try {
            val r = when (source.type) {
                SourceType.M3U, SourceType.LOCAL_FILE -> syncM3u(source)
                SourceType.XTREAM -> syncXtream(source)
                SourceType.STALKER -> syncStalker(source)
                SourceType.HDHOMERUN -> syncHdHomeRun(source)
                SourceType.TVHEADEND -> syncTvHeadend(source)
                SourceType.ENIGMA2 -> syncEnigma2(source)
                SourceType.JELLYFIN, SourceType.EMBY -> syncMediaServer(source)
                SourceType.PLEX -> syncPlex(source)
                SourceType.WEBDAV -> syncWebDav(source)
                SourceType.LOCAL_FOLDER -> syncFolder(source)
            }
            sources.setStatus(sourceId, SyncStatus.OK)
            sources.setCounts(sourceId, r.channels, r.movies, r.series)
            r
        } catch (e: Throwable) {
            android.util.Log.w("Sync", "sync of ${source.name} failed: ${e.javaClass.simpleName}: ${e.message?.take(160)}")
            sources.setStatus(sourceId, SyncStatus.FAILED, source.lastSyncAt)
            sources.setError(sourceId, e.message?.take(200))
            throw e
        }
    }

    // ---- M3U -------------------------------------------------------------------------------------------------

    private suspend fun syncM3u(s: Source, address: String = s.address, headers: Map<String, String> = emptyMap()): Result {
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
                            number = e.channelNumber, logoUrl = e.logo, streamRef = e.url, epgId = e.tvgId ?: e.tvgName, catchupDays = e.catchupDays, sortOrder = order, isRadio = e.radio,
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
        else Http.get(address, s.userAgent, headers) { resp -> resp.body!!.charStream().buffered().useLines { read(it) } }
        if (channels.isEmpty() && movies.isEmpty()) error("That playlist has no channels or movies.")
        replace(s.id, categories.values.toList(), channels, movies, emptyList())
        if (s.epgUrl == null && guideUrl != null) db.sources().upsert(s.copy(epgUrl = guideUrl).toEntity())
        return Result(channels.size, movies.size, 0)
    }

    // ---- Tuners and receivers on the local network --------------------------------------------------------------

    private suspend fun syncHdHomeRun(s: Source): Result {
        val text = Http.text(HdHomeRun.lineupUrl(s.address), s.userAgent)
        val cat = HdHomeRun.parse(s, text)
        if (cat.channels.isEmpty()) error("The tuner has no channels. Run a channel scan in its own setup page first.")
        replace(s.id, cat.categories, cat.channels, emptyList(), emptyList())
        return Result(cat.channels.size, 0, 0)
    }

    private suspend fun syncTvHeadend(s: Source): Result {
        val headers = loginHeaders(s)
        val r = syncM3u(s, TvHeadend.playlistUrl(s.address), headers)
        if (s.epgUrl == null) db.sources().upsert(s.copy(epgUrl = TvHeadend.guideUrl(s.address)).toEntity())
        return r
    }

    private suspend fun syncEnigma2(s: Source): Result {
        val text = Http.text(Enigma2.base(s.address) + "/api/getallservices", s.userAgent, loginHeaders(s))
        val cat = Enigma2.parse(s, text)
        replace(s.id, cat.categories, cat.channels, emptyList(), emptyList())
        return Result(cat.channels.size, 0, 0)
    }

    /** A Basic login for devices that use one; empty when the connection has no user name. */
    private fun loginHeaders(s: Source): Map<String, String> {
        val user = s.username?.takeIf { it.isNotBlank() } ?: return emptyMap()
        return mapOf("Authorization" to Http.basic(user, credentials.load(SourceRepository.credentialRef(s.id)).orEmpty()))
    }

    // ---- Jellyfin, Emby, Plex ------------------------------------------------------------------------------------

    private suspend fun syncMediaServer(s: Source): Result {
        sessions.get(s, renew = true)                    // a fresh sign-in tells the person at once if the login is wrong
        val c = sessions.with(s) { sessions.client.catalog(s, it) }
        if (c.movies.isEmpty() && c.series.isEmpty()) error("The server signed in but has no movies or shows for this account.")
        replace(s.id, c.categories, emptyList(), c.movies, c.series)
        return Result(0, c.movies.size, c.series.size)
    }

    private suspend fun syncPlex(s: Source): Result {
        val token = credentials.load(SourceRepository.credentialRef(s.id)).orEmpty()
        if (token.isBlank()) error("Plex needs an access token. Put it in the password field.")
        val c = plex.catalog(s, token)
        if (c.movies.isEmpty() && c.series.isEmpty()) error("The server has no movies or shows for this account.")
        replace(s.id, c.categories, emptyList(), c.movies, c.series)
        return Result(0, c.movies.size, c.series.size)
    }

    // ---- Files: WebDAV and a folder on this device ----------------------------------------------------------------

    private suspend fun syncWebDav(s: Source): Result {
        val found = dav.crawl(s, loginHeaders(s))
        if (found.isEmpty()) error("No video files were found on the share.")
        val (cats, movies) = VideoFiles.catalog(s, found) { "dav:${it.path}" }
        replace(s.id, cats, emptyList(), movies, emptyList())
        return Result(0, movies.size, 0)
    }

    private suspend fun syncFolder(s: Source): Result {
        val found = listFolder(s.address)
        if (found.isEmpty()) error("No video files were found in that folder.")
        val (cats, movies) = VideoFiles.catalog(s, found) { it.path }          // the address of the file itself (content://…)
        replace(s.id, cats, emptyList(), movies, emptyList())
        return Result(0, movies.size, 0)
    }

    // ---- Stalker / Ministra: live TV ---------------------------------------------------------------------------

    private val stalker = app.streamsetu.core.net.StalkerClient()
    val stalkerClient get() = stalker

    private suspend fun syncStalker(s: Source): Result {
        if (s.username.isNullOrBlank()) error("A Stalker portal needs the MAC address of the box it should act as.")
        val genres = stalker.genres(s)
        val channels = stalker.channels(s)
        if (channels.isEmpty()) error("The portal signed in but returned no channels.")
        val radioGenres = genres.filter { it.title.contains("radio", ignoreCase = true) }.map { it.id }.toSet()
        val cats = genres.mapIndexed { i, g -> CategoryEntity("${s.id}:CHANNEL:${g.id}", s.id, ContentKind.CHANNEL.name, g.title, i) }
        val rows = channels.mapIndexedNotNull { i, ch ->
            if (ChannelFilter.isDivider(ch.name)) null
            else ChannelEntity("${s.id}:ch:${ch.id}", s.id, ch.genreId?.takeIf { g -> genres.any { it.id == g } }?.let { "${s.id}:CHANNEL:$it" }, ch.name, ch.number, ch.logo, "stalker:${ch.cmd}", ch.epgId, 0, i, 0, ch.genreId in radioGenres)
        }
        replace(s.id, cats, rows, emptyList(), emptyList())
        return Result(rows.size, 0, 0)
    }

    private fun stableId(e: M3uEntry) = (e.tvgId ?: "") + "|" + e.name + "|" + e.url.hashCode()

    // ---- Xtream ----------------------------------------------------------------------------------------------

    /** Many Xtream panels cut their lists short, or refuse them, for a client they do not know, so the lists are asked for as a player they know would (the Apple apps do the same). */
    private fun xtreamAgent(s: Source) = s.userAgent?.takeIf { it.isNotBlank() } ?: "VLC/3.0.20 LibVLC/3.0.20"

    private suspend fun syncXtream(s: Source): Result {
        val user = s.username.orEmpty()
        val pass = credentials.load(SourceRepository.credentialRef(s.id)).orEmpty()
        val host = s.address
        /** The items of a list, made one at a time as they are read, so the whole answer is never held in memory at once. */
        fun <T : Any> read(action: String, make: (Int, JsonObject) -> T?): List<T> {
            val out = ArrayList<T>(); var i = 0
            Http.get(Xtream.api(host, user, pass, action), xtreamAgent(s)) { resp -> Xtream.forEachObject(resp.body!!.byteStream()) { o -> make(i++, o)?.let { out += it } } }
            return out
        }
        fun fetch(action: String) = read(action) { _, o -> o }

        val auth = Xtream.parseObject(Http.text(Xtream.api(host, user, pass), xtreamAgent(s)))
        val info = auth?.get("user_info") as? JsonObject
        if (info == null || info.int("auth") == 0) error("The server refused the login. Check the user name and password.")
        resolver?.rememberAccount(s.id, info.str("status").orEmpty(), info.str("exp_date")?.toDoubleOrNull()?.toLong() ?: 0L)
        info.str("max_connections")?.toIntOrNull()?.let { resolver?.rememberMaxConnections(s.id, it) }
        resolver?.remember(s.id, (info["allowed_output_formats"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull }.orEmpty())

        val categories = ArrayList<CategoryEntity>()
        fun cats(action: String, kind: ContentKind) = fetch(action).forEachIndexed { i, o ->
            val id = o.str("category_id") ?: return@forEachIndexed
            categories += CategoryEntity("${s.id}:${kind.name}:$id", s.id, kind.name, o.str("category_name") ?: "Category $id", i)
        }
        cats("get_live_categories", ContentKind.CHANNEL)
        val radioCategories = categories.filter { it.kind == ContentKind.CHANNEL.name && it.name.contains("radio", ignoreCase = true) }.map { it.id }.toSet()
         cats("get_vod_categories", ContentKind.MOVIE); cats("get_series_categories", ContentKind.SERIES)

        val channels = read("get_live_streams") { i, o ->
            val id = o.str("stream_id") ?: return@read null
            if (ChannelFilter.isDivider(o.str("name").orEmpty())) return@read null
            ChannelEntity("${s.id}:ch:$id", s.id, o.str("category_id")?.let { "${s.id}:CHANNEL:$it" }, o.str("name") ?: "Channel $id", o.int("num"),
                o.str("stream_icon"), "live:$id:m3u8", o.str("epg_channel_id"), o.int("tv_archive_duration") ?: 0, i, o.str("added")?.toLongOrNull() ?: 0,
                radioCategories.contains("${s.id}:CHANNEL:" + o.str("category_id")))
        }
        val movies = read("get_vod_streams") { _, o ->
            val id = o.str("stream_id") ?: return@read null
            MovieEntity("${s.id}:mv:$id", s.id, o.str("category_id")?.let { "${s.id}:MOVIE:$it" }, o.str("name") ?: "Movie $id", o.str("stream_icon"),
                year(o.str("year") ?: o.str("releaseDate")), o.str("rating"), null, "movie:$id:${o.str("container_extension") ?: "mp4"}", o.str("added")?.toLongOrNull() ?: 0)
        }
        val seriesList = ArrayList<JsonObject>()
        val series = read("get_series") { _, o ->
            seriesList += o
            val id = o.str("series_id") ?: return@read null
            SeriesEntity("${s.id}:sr:$id", s.id, o.str("category_id")?.let { "${s.id}:SERIES:$it" }, o.str("name") ?: "Series $id", o.str("cover"),
                (o["backdrop_path"] as? kotlinx.serialization.json.JsonArray)?.firstOrNull()?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content },
                year(o.str("year") ?: o.str("releaseDate")), o.str("rating"), o.str("plot"), id, o.str("last_modified")?.toLongOrNull() ?: 0)
        }
        android.util.Log.i("Sync", "xtream ${s.name}: ${categories.size} folders, ${channels.size} channels, ${movies.size} movies, ${series.size} series")
        replace(s.id, categories, channels, movies, series)
        // A series list already names the cast and directors: they are kept so a person can be searched for.
        runCatching {
            val raw = db.openHelper.writableDatabase
            seriesList.forEach { o ->
                val id = o.str("series_id") ?: return@forEach
                val names = splitNames(o.str("cast")) + splitNames(o.str("director"))
                if (names.isNotEmpty()) app.streamsetu.core.data.db.PeopleIndex.save(raw, "${s.id}:sr:$id", "SERIES", s.id, names, app.streamsetu.core.data.repo.SearchText::normalize)
            }
        }
        return Result(channels.size, movies.size, series.size)
    }

    /** A series' episodes are read when the person opens it. */
    suspend fun loadEpisodes(series: Series): Int = withContext(Dispatchers.IO) {
        val src = sources.get(series.sourceId) ?: return@withContext 0
        if (src.type == SourceType.JELLYFIN || src.type == SourceType.EMBY || src.type == SourceType.PLEX) return@withContext loadMediaEpisodes(src, series)
        if (src.type != SourceType.XTREAM) return@withContext 0
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val started = System.currentTimeMillis()
        val text = try { Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_series_info", "&series_id=${series.providerId}"), xtreamAgent(src)) }
            catch (e: Throwable) { android.util.Log.w("Sync", "episodes of \"${series.title}\" (#${series.providerId}) not fetched after ${System.currentTimeMillis() - started} ms: ${e.javaClass.simpleName}: ${e.message?.take(120)}"); throw e }
        val obj = Xtream.parseObject(text)
        if (obj == null) { android.util.Log.w("Sync", "episodes of \"${series.title}\" (#${series.providerId}): ${text.length} characters that are not a JSON object"); return@withContext 0 }
        val root = obj["episodes"]
        val out = Xtream.episodes(obj).map { r ->
            EpisodeEntity("${series.sourceId}:ep:${r.id}", series.id, r.season, r.number, r.title, r.plot, r.image, r.durationSecs, "series:${r.id}:${r.extension}")
        }
        android.util.Log.i("Sync", "episodes of \"${series.title}\" (#${series.providerId}): ${text.length} characters in ${System.currentTimeMillis() - started} ms, layout ${root?.let { it::class.java.simpleName } ?: "missing"}, " +
            "${out.size} episodes in seasons ${out.groupingBy { it.season }.eachCount().toSortedMap()}")
        val known = db.extras().episodeIds(series.id).toSet()
        db.catalog().putEpisodes(out)
        // An episode that shows up after the series was already read, in a series the person has watched, is flagged as new.
        if (known.isNotEmpty() && series.id in db.extras().seriesWithProgress()) {
            val fresh = out.filter { it.id !in known }
            if (fresh.isNotEmpty()) db.extras().putNewEpisodes(fresh.map { app.streamsetu.core.data.db.NewEpisodeEntity(it.id, series.id, System.currentTimeMillis()) })
        }
        out.size
    }

    private suspend fun loadMediaEpisodes(src: Source, series: Series): Int {
        val rows = if (src.type == SourceType.PLEX) plex.episodes(src, credentials.load(SourceRepository.credentialRef(src.id)).orEmpty(), series.providerId, series.id)
                   else sessions.with(src) { sessions.client.episodes(src, it, series.providerId, series.id) }
        val known = db.extras().episodeIds(series.id).toSet()
        db.catalog().putEpisodes(rows)
        if (known.isNotEmpty() && series.id in db.extras().seriesWithProgress()) {
            val fresh = rows.filter { it.id !in known }
            if (fresh.isNotEmpty()) db.extras().putNewEpisodes(fresh.map { app.streamsetu.core.data.db.NewEpisodeEntity(it.id, series.id, System.currentTimeMillis()) })
        }
        return rows.size
    }

    private fun splitNames(s: String?): List<String> = s.orEmpty().split(',', '/', '|').map { it.trim() }.filter { it.isNotEmpty() }

    /**
     * The people in a movie, for the cast index: null when this kind of playlist has no details, an empty list when the playlist knows nobody, and an
     * exception when the playlist could not be reached (so the caller can try again later instead of marking the movie as asked about).
     */
    suspend fun peopleOf(movie: app.streamsetu.core.model.Movie): List<String>? = withContext(Dispatchers.IO) {
        val src = sources.get(movie.sourceId) ?: return@withContext null
        if (src.type != SourceType.XTREAM) return@withContext null
        val vodId = movie.streamRef.split(':').getOrNull(1) ?: return@withContext null
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val obj = Xtream.parseObject(Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_vod_info", "&vod_id=$vodId"), xtreamAgent(src))) ?: return@withContext emptyList()
        val info = obj["info"] as? JsonObject ?: return@withContext emptyList()
        splitNames(info.str("cast") ?: info.str("actors")) + splitNames(info.str("director"))
    }

    data class MovieInfo(val plot: String?, val cast: String?, val director: String?, val genre: String?, val duration: String?, val backdrop: String?, val releaseDate: String?)
    private val movieInfoCache = java.util.concurrent.ConcurrentHashMap<String, MovieInfo>()

    private val shortEpgCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Long, List<app.streamsetu.core.model.EpgProgram>>>()

    /** The coming programmes of one live channel, asked of the provider itself (`get_short_epg`): used when the downloaded guide has nothing for the channel. Remembered for ten minutes. */
    suspend fun shortEpg(ch: app.streamsetu.core.model.Channel, limit: Int = 12): List<app.streamsetu.core.model.EpgProgram> = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        shortEpgCache[ch.id]?.let { (at, list) -> if (now - at < 600_000L) return@withContext list }
        val src = sources.get(ch.sourceId) ?: return@withContext emptyList()
        if (src.type != SourceType.XTREAM) return@withContext emptyList()
        val streamId = ch.streamRef.split(':').getOrNull(1) ?: return@withContext emptyList()
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val obj = runCatching { Xtream.parseObject(Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_short_epg", "&stream_id=$streamId&limit=$limit"), xtreamAgent(src))) }.getOrNull() ?: return@withContext emptyList()
        fun text(v: String?): String {
            if (v.isNullOrBlank()) return ""
            val t = v.trim()
            // Providers send the title and description as Base64; a few send plain text. A plain word can also be valid Base64, so the decoded text must look like text.
            val looksBase64 = t.length >= 4 && t.length % 4 == 0 && t.all { it.isLetterOrDigit() || it == '+' || it == '/' || it == '=' }
            if (looksBase64) runCatching { String(android.util.Base64.decode(t, android.util.Base64.DEFAULT), Charsets.UTF_8) }.getOrNull()?.takeIf { d -> d.isNotBlank() && d.none { c -> c.isISOControl() && c != '\n' && c != '\t' } }?.let { return it }
            return t
        }
        fun stamp(seconds: String?, dateTime: String?): Long? {
            seconds?.toLongOrNull()?.let { return it * 1000 }
            return dateTime?.let { runCatching { java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US).parse(it)?.time }.getOrNull() }
        }
        val listings = obj["epg_listings"] as? kotlinx.serialization.json.JsonArray ?: return@withContext emptyList()
        val out = listings.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val start = stamp(o.str("start_timestamp"), o.str("start")) ?: return@mapNotNull null
            val end = stamp(o.str("stop_timestamp") ?: o.str("end_timestamp"), o.str("end") ?: o.str("stop")) ?: return@mapNotNull null
            val title = text(o.str("title")).ifBlank { return@mapNotNull null }
            app.streamsetu.core.model.EpgProgram(ch.id, start, end, title, text(o.str("description")).ifBlank { null })
        }.filter { it.endMs > now }.sortedBy { it.startMs }
        shortEpgCache[ch.id] = now to out
        out
    }

    /** A movie's story, cast and so on, from the provider (`get_vod_info`). Remembered for the session. */
    suspend fun movieInfo(movie: app.streamsetu.core.model.Movie): MovieInfo? = withContext(Dispatchers.IO) {
        movieInfoCache[movie.id]?.let { return@withContext it }
        val src = sources.get(movie.sourceId) ?: return@withContext null
        if (src.type != SourceType.XTREAM) return@withContext null
        val vodId = movie.streamRef.split(':').getOrNull(1) ?: return@withContext null
        val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
        val obj = runCatching { Xtream.parseObject(Http.text(Xtream.api(src.address, src.username.orEmpty(), pass, "get_vod_info", "&vod_id=$vodId"), xtreamAgent(src))) }.getOrNull() ?: return@withContext null
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

    private val store = CatalogStore(db)

    private suspend fun replace(sourceId: String, cats: List<CategoryEntity>, ch: List<ChannelEntity>, mv: List<MovieEntity>, sr: List<SeriesEntity>) = store.replace(sourceId, cats, ch, mv, sr)
}

/** Providers put divider rows in the channel list ("####### Bulgaria #######", "=== SPORTS ==="). They are not streams. */
object ChannelFilter {
    fun isDivider(name: String): Boolean {
        val letters = name.count { it.isLetterOrDigit() }
        val marks = name.count { it == '#' || it == '=' || it == '*' || it == '_' || it == '-' || it == '~' || it == '•' }
        return name.isBlank() || (marks >= 4 && marks >= letters / 2)
    }
}
