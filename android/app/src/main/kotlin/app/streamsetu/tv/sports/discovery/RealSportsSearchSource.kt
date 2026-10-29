package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.sports.SportsEventService
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.ui.screens.sports.RealSportsDeps
import app.streamsetu.tv.ui.screens.sports.SportsLoad
import app.streamsetu.tv.ui.screens.sports.SportsScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.util.TimeZone

/** Search's view of the Sports screens' own data: the same scope, the same window and the same event cache as the hub. */
class RealSportsSearchSource(private val c: AppContainer) : SportsSearch.Source {
    private val deps = RealSportsDeps(c)
    override fun now() = System.currentTimeMillis()
    override val zone: TimeZone get() = TimeZone.getDefault()
    override suspend fun contextKey(): String = key(deps.scope.first())
    override suspend fun load(): SportsLoad { val (from, to) = SportsWindow.hub(now()); return deps.load(deps.scope.first(), from, to) }
    override suspend fun follows(): FollowSet = c.sportsFollows.current()
    override suspend fun recordings(): List<SportsRecordingEntity> = c.sportsRecordings.recordings.first()

    /** Changes the moment who may see what changes, so a Search screen can drop pending Sports results at once. */
    val contextFlow: Flow<String> = deps.scope.map(::key)

    private fun key(s: SportsScope) = SportsEventService.hash("${s.sourceIds.sorted()}|${s.profileId}|${s.hideAdult}|${s.lockedFolderIds.sorted()}|${s.hiddenChannelIds.sorted()}")
}
