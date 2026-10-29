package app.streamsetu.tv.sports

import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.playback.ErrorKind
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.PlayStart
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * The Sports side of Live TV playback, made from the application's own services. [play] is `AppContainer.play`, the action every Live TV channel choice runs, so a Sports stream is resolved,
 * authenticated, routed (App DNS, proxy, headers, redirect checks), decoded and recovered exactly as a Live TV one is. Nothing here builds or sees a stream address.
 */
class RealSportsPlaybackDeps(private val c: AppContainer) : SportsPlaybackDeps {
    override val profileId: String get() = c.profiles.activeId.value
    override val activeSourceIds: Set<String> get() = c.library.sourceIds.value.toSet()
    override suspend fun channel(id: String): Channel? = c.catalog.channel(id)
    override suspend fun sourceEnabled(sourceId: String): Boolean = c.sources.get(sourceId)?.let { it.enabled && !it.draft } == true
    override suspend fun folderLocked(categoryId: String?): Boolean = categoryId != null && categoryId in c.folders.lockedIdsNow()
    override suspend fun adultBlocked(categoryId: String?): Boolean =
        categoryId != null && c.parental.hideAdult.value && c.db.catalog().categoryName(categoryId)?.let(ParentalControls::isAdultName) == true
    override suspend fun hidden(channelId: String): Boolean = c.db.extras().channelPrefsNow().any { it.channelId == channelId && it.hidden }
    override suspend fun sourceNames(): Map<String, String> = c.db.sources().all().associate { it.id to it.name }
    override fun play(channel: Channel, onResult: (PlayStart) -> Unit) { val item = ChannelPlayable(channel); c.play(item, listOf(item), onResult = onResult) }
    override fun stop() { c.playback.stop() }
    override fun nowMs(): Long = System.currentTimeMillis()

    override val phase: Flow<PlaybackPhase> = combine(c.playback.current, c.playback.state) { item, st ->
        val id = (item as? ChannelPlayable)?.channel?.id
        when (st) {
            PlaybackState.Resolving, PlaybackState.Buffering, is PlaybackState.Retrying -> PlaybackPhase(id, PhaseKind.LOADING)
            PlaybackState.Playing, PlaybackState.Paused -> PlaybackPhase(id, PhaseKind.PLAYING)
            is PlaybackState.Failed -> PlaybackPhase(id, PhaseKind.FAILED, when (st.error.kind) {
                ErrorKind.NO_NETWORK -> PlayFailure.NETWORK
                ErrorKind.SERVER_REFUSED, ErrorKind.AUTH -> PlayFailure.REFUSED
                ErrorKind.NOT_FOUND -> PlayFailure.NOT_FOUND
                ErrorKind.TIMEOUT -> PlayFailure.TIMEOUT
                ErrorKind.FORMAT, ErrorKind.DECODER, ErrorKind.DRM -> PlayFailure.FORMAT
                ErrorKind.UNKNOWN -> PlayFailure.OTHER
            })
            PlaybackState.Idle, PlaybackState.Ended -> PlaybackPhase(id, PhaseKind.IDLE)
        }
    }.distinctUntilChanged { a, b -> a.channelId == b.channelId && a.kind == b.kind && a.failure == b.failure }

    private val decodes4K: Boolean by lazy { c.maintenance.hardwareDecoders().any { it == "H.265 (HEVC)" || it == "VP9" || it == "AV1" } }

    override fun baseRank(): RankInput = RankInput(
        preferredLanguage = c.settings.audioLanguage.value.takeIf { it.isNotBlank() },
        preferredSourceIds = c.library.sourceIds.value,
        healthyChannelIds = emptySet(),          // the app keeps no channel health between sessions
        deviceDecodes4K = decodes4K,
    )
}
