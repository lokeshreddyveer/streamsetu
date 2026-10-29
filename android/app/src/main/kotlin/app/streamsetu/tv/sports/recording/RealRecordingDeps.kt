package app.streamsetu.tv.sports.recording

import android.content.Context
import android.os.StatFs
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.net.RecordableFormat
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.record.GateDecision
import app.streamsetu.tv.record.RecordingFailure
import app.streamsetu.tv.record.RecordingGate
import app.streamsetu.tv.record.ScheduledRec
import app.streamsetu.tv.record.ScheduledRecordings
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.sports.PlayRejection
import app.streamsetu.tv.sports.RealSportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import app.streamsetu.tv.sports.SportsGuideInputs
import app.streamsetu.core.data.repo.ParentalControls
import kotlinx.coroutines.flow.StateFlow

/** The scheduled-recording service, as the Sports recordings use it. */
class ScheduledRecordingsExecutor(private val context: Context) : RecordingExecutor {
    override val items: StateFlow<List<ScheduledRec>> get() = ScheduledRecordings.items
    override fun refresh() = ScheduledRecordings.load(context)
    override fun schedule(r: ScheduledRec) = ScheduledRecordings.scheduleWith(context, r)
    override fun reschedule(id: String, startMs: Long, endMs: Long) = ScheduledRecordings.reschedule(context, id, startMs, endMs)
    override fun cancel(id: String) = ScheduledRecordings.cancel(context, id)
    override fun stop(id: String) = ScheduledRecordings.stop(context, id)
}

/** The recordings folder, as a place to write. */
class FolderStorage(private val folder: java.io.File) : StorageProbe {
    override fun freeBytes(): Long = runCatching { StatFs((if (folder.exists()) folder else folder.parentFile ?: folder).path).availableBytes }.getOrDefault(0L)
    override fun writable(): Boolean = runCatching { folder.mkdirs(); folder.isDirectory && folder.canWrite() }.getOrDefault(false)
}

/** The app's services as the Sports recordings use them. */
class RealRecordingDeps(private val context: Context, c: AppContainer) : RealSportsAuthorization(c), RecordingDeps {
    override val activeProfile: StateFlow<String> get() = c.profiles.activeId
    override fun nowMs() = System.currentTimeMillis()
    override fun libraryKey(): String = c.library.activeId.value.orEmpty()
    override fun providerMax(sourceId: String): Int = c.resolver.accountStatus(sourceId)?.maxConnections ?: 0
    override fun playingSources(): List<String> = RealRecordingGate.playingSources(c)
    override fun format(channel: Channel): RecordableFormat = c.resolver.recordableFormat(channel.sourceId, channel.streamRef)
    override val storage: StorageProbe = FolderStorage(c.recordingsFolder)
    override val executor: RecordingExecutor = ScheduledRecordingsExecutor(context)
    override fun newId(): String = java.util.UUID.randomUUID().toString()
    override suspend fun events(fromMs: Long, toMs: Long): List<SportsEvent> {
        val ctx = SportsGuideInputs.context(c.db, profileId, c.parental.hideAdult.value, c.folders.lockedIdsNow(), ParentalControls::isAdultName)
        return c.sportsService.events(fromMs, toMs, ctx)
    }
    override fun rankInput(eventId: String): RankInput = c.sportsPlayback.rankInput(eventId)
    override suspend fun isXtream(sourceId: String): Boolean = c.sources.get(sourceId)?.type == app.streamsetu.core.model.SourceType.XTREAM
    override fun epgOffsetMs(): Long = c.ui.epgOffsetMinutes.value * 60_000L
    override suspend fun programme(channel: Channel, shiftedStartMs: Long): Pair<Long, Long>? {
        val epgId = c.epg.resolve(listOf(channel))[channel.id] ?: return null
        val shift = epgOffsetMs()
        return c.db.epg().window(listOf(epgId), shiftedStartMs - shift - 60_000L, shiftedStartMs - shift + 60_000L).firstOrNull { kotlin.math.abs(it.startMs - (shiftedStartMs - shift)) <= 5 * 60_000L }?.let { it.startMs to it.endMs }
    }
    override fun playArchive(channel: Channel, title: String, storedStartMs: Long, storedEndMs: Long, onResult: (app.streamsetu.tv.PlayStart) -> Unit) {
        val item = app.streamsetu.core.model.CatchUpPlayable(channel, title, storedStartMs, storedEndMs)
        c.play(item, listOf(item), onResult = onResult)
    }
}

/** What the shared recording check needs to read, so the check itself can be tested against scripted answers. */
interface GateDeps : SportsAuthorization {
    fun format(channel: Channel): RecordableFormat
    fun providerMax(sourceId: String): Int
    /** Recordings running now, not counting [excluding]. */
    fun activeRecordings(excluding: String): List<ScheduledRec>
    /** One entry per connection that playback and Multi-View are using now. */
    fun playingSources(): List<String>
    val storage: StorageProbe
    /** The extra check for a recording that came from Sports (its own row read by its schedule id); null if allowed. */
    suspend fun sportsCheck(rec: ScheduledRec): RecordingFailure?
    /** Another authorized, recordable feed of a Sports recording's event, for when the chosen channel is unusable before it starts. */
    suspend fun alternate(rec: ScheduledRec, failed: String, nowMs: Long): Channel?
}

/**
 * The check every scheduled recording passes when it is due, Guide and Sports alike. It reads the channel afresh from the library and rechecks the profile, the open library, the connection, the
 * folder lock, hidden channels, the adult and kids rules and whether the connection is on; the capacity for one more recording (the provider's connections, the device's two); and the free space.
 * A recording made from Sports also has its own row read by its schedule id (cancelled, finished and review-required ones are refused) and may use another authorized, recordable feed of the same
 * event if its channel has become unusable. Nothing the alarm carried, and nothing saved when it was scheduled, authorizes it.
 */
class SharedRecordingGate(private val d: GateDeps) : RecordingGate {
    override suspend fun check(rec: ScheduledRec, nowMs: Long): GateDecision {
        val profile = d.profileId
        if (rec.profileId.isNotEmpty() && rec.profileId != profile) return GateDecision.Refuse(RecordingFailure.PROFILE_CHANGED)
        if (rec.origin == SportsRecordingService.ORIGIN) d.sportsCheck(rec)?.let { return GateDecision.Refuse(it) }
        var channel = d.channel(rec.channelId)
        var failure = failureOf(channel, rec.sourceId, profile)
        if (failure != null && rec.origin == SportsRecordingService.ORIGIN) {
            val alt = d.alternate(rec, rec.channelId, nowMs)                                     // before anything has started, another authorized feed of the same event may be used
            if (alt != null && failureOf(alt, alt.sourceId, profile) == null) { channel = alt; failure = null }
        }
        val ch = channel
        if (failure != null || ch == null) return GateDecision.Refuse(failure ?: RecordingFailure.CHANNEL_MISSING)
        val active = d.activeRecordings(rec.id)
        when (RecordingCapacity.now(d.providerMax(ch.sourceId), active.count { it.sourceId == ch.sourceId }, active.size, d.playingSources().count { it == ch.sourceId }, 0)) {
            CapacityResult.CONNECTION_LIMIT -> return GateDecision.Refuse(RecordingFailure.CONNECTION_LIMIT)
            CapacityResult.DEVICE_RECORDING_LIMIT -> return GateDecision.Refuse(RecordingFailure.DEVICE_RECORDING_LIMIT)
            CapacityResult.OK -> {}
        }
        val verdict = RecordingStorage.verdict(RecordingStorage.estimate((rec.endMs + rec.postMs - nowMs).coerceAtLeast(60_000L), null), d.storage)
        if (verdict == StorageVerdict.NOT_ENOUGH || verdict == StorageVerdict.UNAVAILABLE) return GateDecision.Refuse(RecordingFailure.STORAGE)
        return GateDecision.Go(ch.name, ch.streamRef)
    }

    private suspend fun failureOf(ch: Channel?, expectedSource: String, profile: String): RecordingFailure? {
        if (ch == null || ch.sourceId != expectedSource) return RecordingFailure.CHANNEL_MISSING
        SportsAuthorizer.refusal(d, ch, profile)?.let { r ->
            return when (r) { PlayRejection.PROFILE_CHANGED -> RecordingFailure.PROFILE_CHANGED; PlayRejection.SOURCE_OFF -> RecordingFailure.SOURCE_OFF; PlayRejection.CHANNEL_MISSING -> RecordingFailure.CHANNEL_MISSING; else -> RecordingFailure.UNAUTHORIZED }
        }
        if (d.format(ch) == RecordableFormat.HLS) return RecordingFailure.UNSUPPORTED_FORMAT
        return null
    }
}

/** The check, made from the app's own services. */
class RealRecordingGate(private val c: AppContainer) : RecordingGate by SharedRecordingGate(object : GateDeps, SportsAuthorization by RealSportsAuthorization(c) {
    override fun format(channel: Channel) = c.resolver.recordableFormat(channel.sourceId, channel.streamRef)
    override fun providerMax(sourceId: String) = c.resolver.accountStatus(sourceId)?.maxConnections ?: 0
    override fun activeRecordings(excluding: String) = ScheduledRecordings.items.value.filter { it.state == ScheduledRec.RECORDING && it.id != excluding }
    override fun playingSources() = playingSources(c)
    override val storage: StorageProbe = FolderStorage(c.recordingsFolder)
    override suspend fun sportsCheck(rec: ScheduledRec) = c.sportsRecordings.executionCheck(rec)
    override suspend fun alternate(rec: ScheduledRec, failed: String, nowMs: Long) = c.sportsRecordings.alternateChannel(rec, failed, nowMs)
}) {
    companion object {
        /** One entry per connection that playback and Multi-View are using now. */
        fun playingSources(c: AppContainer): List<String> {
            val playing = (c.playback.current.value as? ChannelPlayable)?.takeIf { c.playback.state.value.let { s -> s == PlaybackState.Playing || s == PlaybackState.Buffering || s == PlaybackState.Resolving } }
            return listOfNotNull(playing?.channel?.sourceId) + c.sportsMultiview.session.activeSources()
        }
    }
}
