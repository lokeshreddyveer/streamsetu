package app.streamsetu.tv

import android.app.Application
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.HiltAndroidApp
import app.streamsetu.tv.di.kindOf
import app.streamsetu.core.settings.AppSettings
import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.CatalogRepository
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import app.streamsetu.core.net.StreamResolver
import app.streamsetu.core.playback.PlaybackController
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.SyncService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The single place screens ask for what they need. Everything inside is built by Hilt (see di/AppModule); this class only adds the app-wide behaviour that joins them. */
@Singleton
class AppContainer @Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext val context: android.content.Context,
    val appScope: CoroutineScope,
    val db: AppDatabase,
    val credentials: CredentialStore,
    val sources: SourceRepository,
    val catalog: CatalogRepository,
    val library: app.streamsetu.core.data.repo.LibraryRepository,
    val folders: app.streamsetu.core.data.repo.FolderRepository,
    val browse: app.streamsetu.core.data.repo.BrowseRepository,
    val search: app.streamsetu.core.data.repo.SearchRepository,
    val user: UserRepository,
    val epg: EpgService,
    val parental: ParentalControls,
    val settings: AppSettings,
    val ui: app.streamsetu.core.settings.UiPrefs,
    val collections: app.streamsetu.core.data.repo.CollectionRepository,
    val maintenance: app.streamsetu.core.data.repo.MaintenanceService,
    val resolver: StreamResolver,
    val sync: SyncService,
    val playback: PlaybackController,
    val updates: app.streamsetu.tv.update.UpdateManager,
    val globalSearch: app.streamsetu.core.data.repo.GlobalSearch,
    val stats: app.streamsetu.core.data.repo.StatisticsRepository,
    val cast: CastSupport,
    val channelPrefs: app.streamsetu.core.data.repo.ChannelPrefs,
) {
    /** What the player plays next: the channels of the list it was started from, or the episodes of a series. */
    var queue: List<Playable> = emptyList()
    var queueIndex: Int = 0
    /** The channels Multi-View opens with (set by the player when it hands over). */
    var multiViewStart: List<app.streamsetu.core.model.Channel> = emptyList()

    /** Seconds left before the next episode starts by itself; 0 when none is waiting. */
    val nextEpisodeIn = kotlinx.coroutines.flow.MutableStateFlow(0)

    /** Where recordings of live channels are kept. */
    val recordingsFolder: java.io.File = java.io.File(context.getExternalFilesDir(null) ?: context.filesDir, "recordings").also { it.mkdirs() }

    /** Movies and episodes saved on this device to watch without a connection. */
    val downloads = Downloads(context, resolver, {
        val s = playback.state.value
        s == app.streamsetu.core.playback.PlaybackState.Playing || s == app.streamsetu.core.playback.PlaybackState.Buffering || s == app.streamsetu.core.playback.PlaybackState.Resolving
    }, appScope).also { d -> app.streamsetu.core.playback.LocalFiles.finder = { id ->
        d.localUri(id) ?: app.streamsetu.core.data.repo.RecordingFiles.fileOf(id)?.let { java.io.File(recordingsFolder, it) }?.takeIf { it.exists() }?.let { android.net.Uri.fromFile(it).toString() }
    } }

    /** Movies and series watched to the end, for the tick on posters. */
    val watchedTitles: kotlinx.coroutines.flow.StateFlow<Set<String>> = db.user().watchedTitles().map { it.toSet() }
        .stateIn(appScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, emptySet<String>())

    /** How far along each started movie or series is (0 to 1), for the bar on posters. */
    val partialTitles: kotlinx.coroutines.flow.StateFlow<Map<String, Float>> = db.user().partialTitles().map { rows -> rows.associate { it.id to it.fraction.toFloat().coerceIn(0f, 0.99f) } }
        .stateIn(appScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, emptyMap<String, Float>())

    /** The titles lined up to play after the one on screen. */
    val watchQueue = app.streamsetu.core.data.repo.WatchQueue(object : app.streamsetu.core.data.repo.QueueStore {
        override fun read() = settings.queueRaw()
        override fun write(value: String) = settings.setQueueRaw(value)
    })

    private var advanceJob: kotlinx.coroutines.Job? = null

    /**
     * What happens when something that is not live ends: the next title in the queue starts at once; otherwise, when "Play the next episode by itself" is on and
     * there is a next episode, a short countdown (shown by the player) and then that episode. Any press of Back or a new start cancels the countdown.
     */
    private fun advanceAfterEnd() {
        advanceJob?.cancel()
        val item = playback.current.value ?: return
        if (item.isLive || item is app.streamsetu.core.model.CatchUpPlayable) return
        advanceJob = appScope.launch {
            watchQueue.popNext()?.let { playQueued(it); return@launch }
            val hasNext = item is EpisodePlayable && queue.indexOfFirst { it.id == item.id }.let { it >= 0 && it < queue.lastIndex }
            if (!hasNext || !settings.playNextAutomatically.value) return@launch
            for (n in 5 downTo 1) {
                nextEpisodeIn.value = n
                kotlinx.coroutines.delay(1000)
                if (playback.state.value != app.streamsetu.core.playback.PlaybackState.Ended || playback.current.value?.id != item.id) { nextEpisodeIn.value = 0; return@launch }
            }
            nextEpisodeIn.value = 0
            step(+1)
        }
    }

    private var subtitleItem: String? = null

    /**
     * A few seconds into a film or episode with no subtitles in the chosen language, the most downloaded one from OpenSubtitles is loaded, when the person turned that on
     * and set up the free account. An episode is asked for by its season and number: a subtitle for the wrong episode is worse than none.
     */
    private fun fetchSubtitleIfWanted() {
        val item = playback.current.value ?: return
        if (!settings.autoSubtitles.value || item.isLive || item is app.streamsetu.core.model.CatchUpPlayable || subtitleItem == item.id) return
        val online = app.streamsetu.tv.ui.screens.OnlineSubtitles(context, credentials)
        if (!online.configured || settings.subtitleMode.value == "OFF") return
        subtitleItem = item.id
        val language = settings.subtitleLanguage.value.ifBlank { "en" }
        appScope.launch {
            kotlinx.coroutines.delay(6_000)
            if (playback.current.value?.id != item.id) return@launch
            if (playback.subtitleTracks.value.any { it.language?.startsWith(language, true) == true }) return@launch
            val hit = runCatching {
                when (item) {
                    is EpisodePlayable -> online.search(item.series.title, null, language, item.episode.season, item.episode.number)
                    is MoviePlayable -> online.search(item.movie.title, item.movie.year, language)
                    else -> emptyList()
                }.firstOrNull()
            }.getOrNull() ?: return@launch
            val file = runCatching { online.download(hit) }.getOrNull() ?: return@launch
            if (playback.current.value?.id == item.id) playback.addSubtitle(file, "$language (automatic)")
        }
    }

    /** Starts a title taken from the queue: a movie plays; a series plays the episode that would be watched next (or the first one). */
    suspend fun playQueued(t: app.streamsetu.core.data.repo.QueuedTitle) {
        when (t.kind) {
            ContentKind.MOVIE -> catalog.movie(t.id)?.let { play(MoviePlayable(it)) }
            ContentKind.SERIES -> {
                val series = catalog.series(t.id) ?: return
                var eps = catalog.episodesOnce(series.id)
                if (eps.isEmpty()) { runCatching { sync.loadEpisodes(series) }; eps = catalog.episodesOnce(series.id) }
                if (eps.isEmpty()) return
                val progress = user.allProgress().first().filterValues { it.seriesId == series.id }
                val plan = app.streamsetu.core.data.repo.EpisodePlan.of(eps, progress)
                val ordered = eps.sortedWith(compareBy({ it.season }, { it.number })).map { EpisodePlayable(it, series) }
                val next = (plan.inProgress ?: plan.forward)?.takeIf { !plan.allFinished || plan.inProgress != null } ?: ordered.first().episode
                play(EpisodePlayable(next, series), ordered)
            }
            else -> {}
        }
    }

    /** Reads who is in each movie, a little at a time, so people can be searched for (see [app.streamsetu.core.sync.PeopleIndexer]). */
    val people = app.streamsetu.core.sync.PeopleIndexer(db, sync) { playback.current.value != null }

    init {
        appScope.launch { runCatching { db.catalog().deleteDividers() } }
        appScope.launch { playback.state.collect { if (it == app.streamsetu.core.playback.PlaybackState.Ended) advanceAfterEnd() } }
        appScope.launch { playback.state.collect { if (it == app.streamsetu.core.playback.PlaybackState.Playing) fetchSubtitleIfWanted() } }
        appScope.launch { playback.state.collect { if (it is app.streamsetu.core.playback.PlaybackState.Failed) tryNextCopy() } }
        appScope.launch { runCatching { PlexTokenCleanup.run(db.openHelper.writableDatabase) } }
    }

    private var featuredCache: List<Playable>? = null
    private var featuredFor: String? = null
    /** The banner mix: picked once per open library (and again after a playlist is read), so it does not reshuffle when you come back to a page. */
    suspend fun featured(): List<Playable> {
        val lib = library.activeId.value
        if (featuredFor != lib) { featuredCache = null; featuredFor = lib }
        return featuredCache ?: catalog.featured(30).also { featuredCache = it }
    }

    /** Reads a playlist, then its guide (a guide that cannot be read never fails the playlist). */
    suspend fun syncWithGuide(sourceId: String): SyncService.Result {
        val r = sync.sync(sourceId)
        featuredCache = null
        people.start()
        runCatching {
            val src = sources.get(sourceId) ?: return@runCatching
            val fallback = if (src.type == SourceType.XTREAM) {
                val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
                "${app.streamsetu.core.parse.Xtream.normalizeHost(src.address)}/xmltv.php?username=${src.username.orEmpty()}&password=$pass"
            } else null
            epg.refresh(src, fallback, resolver.headers(src.id))
        }
        return r
    }

    /** Saves the guide address for a connection and reads that guide now. Returns the number of programmes found. */
    suspend fun setGuideAddress(sourceId: String, url: String?): Int {
        sources.setGuide(sourceId, url)
        val src = sources.get(sourceId) ?: return 0
        val fallback = if (src.type == SourceType.XTREAM) "${app.streamsetu.core.parse.Xtream.normalizeHost(src.address)}/xmltv.php?username=${src.username.orEmpty()}&password=${credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()}" else null
        return runCatching { epg.refresh(src, fallback, resolver.headers(src.id)) }.getOrDefault(-1)
    }

    /** The live channel watched before the current one (the iPhone app's Last Channel). */
    var previousLive: Playable? = null
    fun lastChannel() { previousLive?.let { play(it, queue) } }

    /** The other copies of the title that was just started, best first: if the one playing fails for good, the next is tried. */
    private var fallbackCopies: List<Playable> = emptyList()

    /** The copies of a film, best first: the film itself when the setting is off or it has no other copy. A tie keeps the one the person opened first. */
    suspend fun movieCopies(movie: Movie): List<Movie> {
        if (!settings.bestVersionFirst.value) return listOf(movie)
        val variants = runCatching { search.movieVariants(movie.title) }.getOrDefault(emptyList())
        if (variants.size < 2) return listOf(movie)
        val folderNames = runCatching { folders.folders(ContentKind.MOVIE).first().associate { it.id to it.providerName } }.getOrDefault(emptyMap())
        val all = listOf(movie) + variants.filter { it.id != movie.id }
        return app.streamsetu.core.data.repo.BestVersion.order(all) { m -> listOf(m.title, folderNames[m.categoryId]) }
    }

    /** Starts a film with its best copy, remembering the others to fall back on. */
    fun playBestMovie(movie: Movie, onStart: (Playable) -> Unit) {
        appScope.launch {
            val copies = movieCopies(movie)
            val chosen = copies.first()
            kotlinx.coroutines.withContext(Dispatchers.Main) {
                onStart(MoviePlayable(chosen))
                fallbackCopies = copies.drop(1).map { MoviePlayable(it) }
                if (chosen.id != movie.id) android.widget.Toast.makeText(context, "Playing the best copy of this film", android.widget.Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun tryNextCopy() {
        val next = fallbackCopies.firstOrNull() ?: return
        fallbackCopies = fallbackCopies.drop(1)
        android.widget.Toast.makeText(context, "That copy did not play. Trying another.", android.widget.Toast.LENGTH_SHORT).show()
        play(next, listOf(next), keepCopies = true)
    }

    fun play(item: Playable, queue: List<Playable> = listOf(item), startOver: Boolean = false, keepCopies: Boolean = false) {
        if (!keepCopies) fallbackCopies = emptyList()
        playback.current.value?.takeIf { it.isLive && it.id != item.id }?.let { previousLive = it }
        this.queue = queue
        if (item is ChannelPlayable) settings.lastChannelId = item.id
        queueIndex = queue.indexOfFirst { it.id == item.id }.coerceAtLeast(0)
        UISound.play(UISoundEvent.PLAYBACK_START)
        appScope.launch {
            val resume = if (item.isLive || !item.tracksProgress || startOver) 0 else if (settings.resumeAutomatically.value) user.progress(item.id)?.takeIf { !it.completed }?.positionMs ?: 0 else 0
            kotlinx.coroutines.withContext(Dispatchers.Main) { playback.play(item, resume) }
        }
    }

    /** Channel up / down, or the next episode. */
    fun step(delta: Int) {
        if (queue.isEmpty()) return
        queueIndex = (queueIndex + delta).mod(queue.size)
        play(queue[queueIndex], queue)
    }

}

@HiltAndroidApp
class StreamSetuApp : Application(), coil.ImageLoaderFactory {
    @Inject lateinit var container: AppContainer
    /** Artwork downloads share the connection with the video, so while something plays only a few run at once. */
    private val images = okhttp3.Dispatcher().apply { maxRequests = 16; maxRequestsPerHost = 6 }

    override fun newImageLoader(): coil.ImageLoader = coil.ImageLoader.Builder(this)
        .okHttpClient(okhttp3.OkHttpClient.Builder().dispatcher(images).addInterceptor(ArtworkAuth(container.sources, container.credentials)).build())
        .diskCache { coil.disk.DiskCache.Builder().directory(java.io.File(cacheDir, "image_cache")).maxSizeBytes(160L * 1024 * 1024).build() }
        .crossfade(false)
        .memoryCache { coil.memory.MemoryCache.Builder(this).maxSizePercent(if (Perf.lowEnd(this)) 0.12 else 0.22).build() }
        .allowRgb565(true)                  // posters have no transparency: half the memory and decoding work
        .build()

    override fun onCreate() {
        super.onCreate()
        UISound.init(this, settings = {
            val u = container.ui
            SoundSettings(u.soundsEnabled.value, u.soundTheme.value, u.soundVolume.value, u.navTones.value, u.selectionTones.value, u.confirmationTones.value, u.errorTones.value, u.soundsDuringPlayback.value)
        }, videoPlaying = { container.playback.current.value != null && container.playback.state.value == app.streamsetu.core.playback.PlaybackState.Playing })
        CrashReporter.install(this, runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "?")
        container.appScope.launch {
            // "Refresh on app start": after the screen has settled, each connection is read once, one after another, and never while something plays.
            kotlinx.coroutines.delay(6000)
            if (container.settings.refreshOnStart.value) container.sources.all().filter { !it.draft && it.enabled }.forEach { s ->
                if (container.playback.current.value == null) runCatching { container.syncWithGuide(s.id) }
            }
        }
        container.appScope.launch {
            // The language chosen in Settings (Appearance), now and whenever it changes.
            container.ui.language.collect { setting -> kotlinx.coroutines.withContext(Dispatchers.Main) { app.streamsetu.tv.ui.i18n.I18n.apply(this@StreamSetuApp, setting) } }
        }
        container.appScope.launch {
            // The theme and accent chosen in Settings (Appearance) apply to every screen, now and whenever they change.
            kotlinx.coroutines.flow.combine(container.ui.theme, container.ui.accent) { t, a -> app.streamsetu.tv.ui.theme.Theme.of(t) to app.streamsetu.tv.ui.theme.Accent.of(a) }
                .collect { (t, a) -> kotlinx.coroutines.withContext(Dispatchers.Main) { app.streamsetu.tv.ui.theme.Tokens.apply(t, a) } }
        }
        container.appScope.launch {
            // The proxy chosen in Settings applies to every request, now and whenever it changes.
            kotlinx.coroutines.flow.combine(container.settings.proxyKind, container.settings.proxyHost, container.settings.proxyPort) { k, h, p -> app.streamsetu.core.net.Http.makeProxy(k, h, p) }
                .collect { app.streamsetu.core.net.Http.proxy = it }
        }
        container.appScope.launch {
            // Once a day, a little after start and never while something plays: is there a newer release? (Settings, About, Updates.)
            kotlinx.coroutines.delay(20_000)
            container.updates.checkIfDue()
        }
        if (app.streamsetu.tv.ui.phone.isPhoneDevice(this)) container.appScope.launch {
            // Phones: while something plays, the media service keeps it alive in the background and shows the lock-screen controls.
            var running = false
            container.playback.current.collect { item ->
                if (item != null && !running) running = PlaybackService.start(this@StreamSetuApp)
                if (item == null) running = false
            }
        }
        container.appScope.launch {
            container.playback.state.collect { st ->
                val busy = st == app.streamsetu.core.playback.PlaybackState.Playing || st == app.streamsetu.core.playback.PlaybackState.Buffering
                images.maxRequests = if (busy) 4 else 16; images.maxRequestsPerHost = if (busy) 2 else 6
            }
        }
        // Re-asserts the background refresh the person chose (a no-op when it is already scheduled).
        val hours = getSharedPreferences("settings", MODE_PRIVATE).getInt("bgSyncHours", 0)
        CatalogSyncWorker.schedule(this, hours)
        AutoBackupWorker.schedule(this, container.settings.automaticBackups.value)
    }
}

/** Plays a movie or episode from its saved copy on this device. */
fun playSaved(c: AppContainer, nav: app.streamsetu.tv.nav.Navigator, t: app.streamsetu.core.data.repo.SavedTitle) {
    c.appScope.launch {
        when (t.kind) {
            ContentKind.MOVIE -> c.catalog.movie(t.itemId)?.let { play(c, nav, MoviePlayable(it)) }
            ContentKind.EPISODE -> {
                val e = c.catalog.episode(t.itemId) ?: return@launch
                val series = c.catalog.series(e.seriesId) ?: return@launch
                play(c, nav, EpisodePlayable(e, series))
            }
            else -> {}
        }
    }
}
