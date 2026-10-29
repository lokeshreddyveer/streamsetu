package app.streamsetu.tv.ui.screens.sports

import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.SportsGuideInputs
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import java.util.TimeZone

/** What decides which events this person may see. When any of it changes, what was on screen is cleared at once and rebuilt. */
data class SportsScope(
    val sourceIds: List<String>,
    val profileId: String,
    /** The adult filter or kids mode. */
    val hideAdult: Boolean,
    /** Folders that are PIN-locked and not unlocked right now. */
    val lockedFolderIds: Set<String>,
    val hiddenChannelIds: Set<String>,
)

/** [cacheHit]: the events came from the per-source cache and nothing had to be classified again. */
class SportsLoad(val events: List<SportsEvent>, val revision: String, val cacheHit: Boolean = false)

/** Everything the Sports screen's ViewModel needs from the rest of the app, so a test can supply it and count every call. */
interface SportsDeps {
    /** The security-relevant scope. Emits the current one first, then every change. */
    val scope: Flow<SportsScope>
    /** Ordinary data changes (the guide was written, a playlist changed, the guide time offset changed): refresh and keep the old content. Emits only changes, not an initial value. */
    val dataSignals: Flow<Unit>
    /** One tick per minute (the first at once), for moving events between sections. Never touches the database. */
    val minutes: Flow<Long>
    val zone: TimeZone
    fun now(): Long
    suspend fun sourceNames(): Map<String, String>
    suspend fun hasGuide(): Boolean
    suspend fun load(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad
    /** Events that already ended, for a page's Catch-Up: the same service and the same authorization as [load], over a window the page asked for. */
    suspend fun history(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad = SportsLoad(emptyList(), "")
    /** The longest archive the provider declares for these channels, in days (0: none). */
    suspend fun catchUpDays(channelIds: List<String>): Int = 0
}

/** The real thing, built from the application's services. */
class RealSportsDeps(private val c: AppContainer) : SportsDeps {
    override val scope: Flow<SportsScope> = combine(
        c.library.sourceIds, c.profiles.activeId, c.parental.hideAdult, c.folders.lockedIds(ContentKind.CHANNEL), c.db.extras().channelPrefs().map { l -> l.filter { it.hidden }.map { it.channelId }.toSet() },
    ) { sources, profile, hide, locked, hidden -> SportsScope(sources, profile, hide, locked, hidden) }

    /** Each source is dropped once for its first value (Room emits at once when watched): only later changes count. The guide signal costs one row to read. */
    override val dataSignals: Flow<Unit> = merge(
        c.db.epg().guideTouched().drop(1).map { },
        c.db.sources().observe().drop(1).map { },
        c.ui.epgOffsetMinutes.drop(1).map { },
    )

    override val minutes: Flow<Long> = flow { while (true) { val now = System.currentTimeMillis(); emit(now); delay(60_000L - now % 60_000L) } }
    override val zone: TimeZone get() = TimeZone.getDefault()
    override fun now() = System.currentTimeMillis()

    override suspend fun sourceNames(): Map<String, String> = c.db.sources().all().associate { it.id to it.name }
    override suspend fun hasGuide(): Boolean = c.db.epg().guideStamps().isNotEmpty()

    override suspend fun load(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad {
        val ctx = SportsGuideInputs.context(c.db, scope.profileId, scope.hideAdult, scope.lockedFolderIds, ParentalControls::isAdultName)
        val classifiedBefore = c.sportsService.classifiedSources
        val events = c.sportsService.events(fromMs, toMs, ctx)
        val hit = c.sportsService.classifiedSources == classifiedBefore
        val revision = c.sportsInputs.revisions().toSortedMap().values.joinToString("|").let { app.streamsetu.core.sports.SportsEventService.hash(it) }
        return SportsLoad(events, revision, hit)
    }

    override suspend fun history(scope: SportsScope, fromMs: Long, toMs: Long): SportsLoad = load(scope, fromMs, toMs)

    override suspend fun catchUpDays(channelIds: List<String>): Int =
        channelIds.distinct().chunked(400).maxOfOrNull { ids -> c.db.catalog().channelsByIds(ids).maxOfOrNull { it.catchupDays } ?: 0 } ?: 0
}
