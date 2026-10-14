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
import app.streamsetu.core.net.StreamResolver
import app.streamsetu.core.playback.PlaybackController
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.SyncService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The single place screens ask for what they need. Everything inside is built by Hilt (see di/AppModule); this class only adds the app-wide behaviour that joins them. */
@Singleton
class AppContainer @Inject constructor(
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
) {
    /** What the player plays next: the channels of the list it was started from, or the episodes of a series. */
    var queue: List<Playable> = emptyList()
    var queueIndex: Int = 0

    init {
        appScope.launch { runCatching { db.catalog().deleteDividers() } }      // divider rows read by an earlier version
        // "Play next episode automatically": when an episode ends, the next one of the same series starts.
        appScope.launch {
            playback.state.collect { st ->
                if (st == app.streamsetu.core.playback.PlaybackState.Ended && settings.playNextAutomatically.value) {
                    val ep = playback.current.value as? EpisodePlayable ?: return@collect
                    catalog.nextEpisode(ep.episode)?.takeIf { app.streamsetu.core.data.repo.EpisodePlan.contiguous(ep.episode, it) }?.let { n -> catalog.series(n.seriesId)?.let { s -> kotlinx.coroutines.withContext(Dispatchers.Main) { play(EpisodePlayable(n, s), queue) } } }
                }
            }
        }
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
        runCatching {
            val src = sources.get(sourceId) ?: return@runCatching
            val fallback = if (src.type == SourceType.XTREAM) {
                val pass = credentials.load(SourceRepository.credentialRef(src.id)).orEmpty()
                "${app.streamsetu.core.parse.Xtream.normalizeHost(src.address)}/xmltv.php?username=${src.username.orEmpty()}&password=$pass"
            } else null
            epg.refresh(src, fallback)
        }
        return r
    }

    /** The live channel watched before the current one (the iPhone app's Last Channel). */
    var previousLive: Playable? = null
    fun lastChannel() { previousLive?.let { play(it, queue) } }

    fun play(item: Playable, queue: List<Playable> = listOf(item), startOver: Boolean = false) {
        playback.current.value?.takeIf { it.isLive && it.id != item.id }?.let { previousLive = it }
        this.queue = queue
        if (item is ChannelPlayable) settings.lastChannelId = item.id
        queueIndex = queue.indexOfFirst { it.id == item.id }.coerceAtLeast(0)
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
        .okHttpClient(okhttp3.OkHttpClient.Builder().dispatcher(images).build())
        .diskCache { coil.disk.DiskCache.Builder().directory(java.io.File(cacheDir, "image_cache")).maxSizeBytes(160L * 1024 * 1024).build() }
        .crossfade(false)
        .memoryCache { coil.memory.MemoryCache.Builder(this).maxSizePercent(if (Perf.lowEnd(this)) 0.12 else 0.22).build() }
        .allowRgb565(true)                  // posters have no transparency: half the memory and decoding work
        .build()

    override fun onCreate() {
        super.onCreate()
        CrashReporter.install(this, runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "?")
        container.appScope.launch {
            container.playback.state.collect { st ->
                val busy = st == app.streamsetu.core.playback.PlaybackState.Playing || st == app.streamsetu.core.playback.PlaybackState.Buffering
                images.maxRequests = if (busy) 4 else 16; images.maxRequestsPerHost = if (busy) 2 else 6
            }
        }
        // Re-asserts the background refresh the person chose (a no-op when it is already scheduled).
        val hours = getSharedPreferences("settings", MODE_PRIVATE).getInt("bgSyncHours", 0)
        CatalogSyncWorker.schedule(this, hours)
    }
}
