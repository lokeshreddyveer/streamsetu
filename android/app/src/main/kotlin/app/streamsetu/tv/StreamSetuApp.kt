package app.streamsetu.tv

import android.app.Application
import android.content.Context
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.CatalogRepository
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.net.StreamResolver
import app.streamsetu.core.playback.PlaybackController
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.security.KeystoreCredentialStore
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.SyncService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The one object graph. Built once, handed to every screen; no dependency-injection library, so it reads top to bottom. */
class AppContainer(context: Context) {
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val db: AppDatabase = AppDatabase.open(context)
    val credentials: CredentialStore = KeystoreCredentialStore(context)
    val sources = SourceRepository(db, credentials)
    val catalog = CatalogRepository(db)
    val user = UserRepository(db)
    val sync = SyncService(db, sources, credentials)
    val epg = EpgService(db)
    val parental = app.streamsetu.core.data.repo.ParentalControls(context)
    val resolver = StreamResolver(sources, credentials)

    /** What the player plays next: the channels of the list it was started from, or the episodes of a series. */
    var queue: List<Playable> = emptyList()
    var queueIndex: Int = 0

    val playback: PlaybackController = PlaybackController(
        context, resolver,
        onProgress = { item, pos, dur -> user.saveProgress(item.id, kindOf(item), (item as? EpisodePlayable)?.series?.id, pos, dur) },
        onStarted = { item -> user.recordPlay(item.id, kindOf(item), item.title) },
    )

    /** Reads a playlist, then its guide (a guide that cannot be read never fails the playlist). */
    suspend fun syncWithGuide(sourceId: String): SyncService.Result {
        val r = sync.sync(sourceId)
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

    fun play(item: Playable, queue: List<Playable> = listOf(item)) {
        this.queue = queue
        queueIndex = queue.indexOfFirst { it.id == item.id }.coerceAtLeast(0)
        appScope.launch {
            val resume = if (item.isLive) 0 else user.progress(item.id)?.takeIf { !it.completed }?.positionMs ?: 0
            kotlinx.coroutines.withContext(Dispatchers.Main) { playback.play(item, resume) }
        }
    }

    /** Channel up / down, or the next episode. */
    fun step(delta: Int) {
        if (queue.isEmpty()) return
        queueIndex = (queueIndex + delta).mod(queue.size)
        play(queue[queueIndex], queue)
    }

    private fun kindOf(p: Playable) = when (p) {
        is ChannelPlayable -> ContentKind.CHANNEL
        is MoviePlayable -> ContentKind.MOVIE
        is EpisodePlayable -> ContentKind.EPISODE
    }
}

class StreamSetuApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
