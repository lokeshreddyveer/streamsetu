package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.smartmix.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Smart Mix for the open library on this device: the Room candidate source, the persisted state and the service, behind suspending calls that run on a background dispatcher.
 * Nothing here starts a sync or touches Continue Watching. [invalidate] is called when a lock, a profile, a library or a playlist read changes what a shelf may hold.
 */
class SmartMixHome(
    private val db: AppDatabase,
    visibility: Visibility,
    sourceIds: () -> List<String>,
    preferredLanguage: () -> String?,
    trending: TrendingViewSource?,
    /** Low-end devices: a smaller candidate pool. */
    poolCap: Int? = null,
) {
    val source = RoomCandidateSource(db, visibility, sourceIds, preferredLanguage)
    val service = SmartMixService(source, RoomSmartMixStore(db), trending, poolCap = poolCap)

    fun dayKey(): String = java.time.LocalDate.now().toString()

    /** Drops what was read about the person's activity and restrictions; the next build reads it again. */
    fun invalidate() = source.invalidate()

    /** The Home shelves (hero, For You, Rediscover, preferred language, Top This Week, Trending in your library) that have something to show. */
    suspend fun home(profileId: String): List<BuiltShelf> = withContext(Dispatchers.Default) { service.buildHome(profileId, dayKey()) }

    suspend fun shelf(profileId: String, shelfId: String): BuiltShelf = withContext(Dispatchers.Default) { service.build(profileId, shelfId, dayKey()) }

    /** After the first successful render of a shelf: repeat suppression moves on. */
    suspend fun committed(profileId: String, shelf: BuiltShelf) = withContext(Dispatchers.IO) { service.commitRendered(profileId, shelf) }

    /** "Shuffle recommendations": a new draw for the shelves on screen. Reads only what is already stored; never starts a sync. */
    suspend fun reshuffle(profileId: String, shelfIds: Collection<String> = ShelfSpec.GLOBAL) = withContext(Dispatchers.IO) { service.reshuffle(profileId, shelfIds) }

    suspend fun forgetProfile(profileId: String) = withContext(Dispatchers.IO) { service.forgetProfile(profileId) }
}
