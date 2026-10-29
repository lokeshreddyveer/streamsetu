package app.streamsetu.tv.sports

import androidx.compose.runtime.Immutable
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.PlayStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the player is doing with the channel a Sports request started. Only the channel's id and a fixed word: never an address or a message. */
enum class PhaseKind { IDLE, LOADING, PLAYING, FAILED }
class PlaybackPhase(val channelId: String?, val kind: PhaseKind, val failure: PlayFailure? = null)

/**
 * Everything the Sports playback needs from the rest of the app. The real one is a thin shell over the Live TV services; a test supplies a scripted one and counts the calls.
 * [play] is the Live TV play action itself: Sports has no other way to start a stream, so addresses, headers, App DNS, the proxy, redirect checks, the engine and recovery are all the
 * ones Live TV uses. It reports once how the request ended ([PlayStart]).
 */
interface SportsPlaybackDeps : SportsAuthorization {
    fun play(channel: Channel, onResult: (PlayStart) -> Unit)
    fun stop()
    val phase: Flow<PlaybackPhase>
    fun nowMs(): Long
    /** The parts of the ranking input that belong to the device and the person, not to the event. */
    fun baseRank(): RankInput
}

/** Where the person came from: safe identifiers only. The temporary event id is never a durable identity (not for a recording, a reminder or a sync). */
@Immutable
data class SportsOrigin(val eventId: String, val channelId: String, val generation: Int)

/** One feed the person may switch to. No address, no credential; the channel and connection names are for display only and never leave the screen. */
@Immutable
data class SportsFeedOption(
    val channelId: String, val channelName: String, val sourceName: String,
    val language: String?, val languageInferred: Boolean, val quality: String?, val qualityInferred: Boolean,
    val catchUp: Boolean, val current: Boolean, val recommended: Boolean, val unsupported: Boolean,
)

enum class SportsPlayStatus { IDLE, STARTING, PLAYING, FAILED }

/** A channel that keeps playing after the Sports event it came from is gone. The name is for display only. */
@Immutable
data class SportsHeld(val channelId: String, val channelName: String)

@Immutable
data class SportsPlaybackState(
    /** Set while a Sports request owns the playing channel. [SportsOrigin.channelId] is the feed selected (the previous one stays selected while a switch is running or failing). */
    val origin: SportsOrigin? = null,
    val status: SportsPlayStatus = SportsPlayStatus.IDLE,
    /** The feeds allowed right now, best first. Rebuilt whenever what is allowed can have changed. */
    val options: List<SportsFeedOption> = emptyList(),
    /** The feed a start, a switch or a restoration is for (differs from the selected one while that is running or has failed). */
    val attemptedChannelId: String? = null,
    /** A concise sentence for the person, or null. */
    val message: String? = null,
    /** After a failure: the next best allowed feed, highlighted but never switched to without a choice. */
    val suggestedChannelId: String? = null,
    /** The latest request this state belongs to. A completion that carries an older number is ignored. */
    val request: Int = 0,
    /** The event this stream was started from is gone (the guide changed) but the channel is still allowed and keeps playing in Sports' own embedded player. */
    val held: SportsHeld? = null,
    /** Sports can no longer keep the embedded player (the person left the held channel, or the content was cleared): the screen hands the stream to Live TV's embedded player without restarting it. */
    val handoff: Boolean = false,
) {
    fun canSwitch(): Boolean = origin != null && options.size > 1
}

/**
 * Starts and switches Sports playback. It decides which feed, makes sure that feed is still allowed at the moment of the request, and then hands the channel to the Live TV play action.
 * It owns no player and no stream: the one player, its surface and its recovery are Live TV's.
 *
 *  - Nothing here runs from focus: [watch] and [switchTo] are called by OK on a button.
 *  - Every request is checked again when it is made, and again after those checks, so a profile or library change in between drops the request.
 *  - Every request has a number. The play action reports how it ended (started, refused, overtaken); only the newest request's report changes the state, and a refused or overtaken one
 *    always clears "Starting…".
 *  - A switch remembers the feed that was playing. If the new feed fails after it replaced the player, that same feed is started again through the same play action. This restores what
 *    the person was watching; it never moves them to a feed they did not choose.
 *  - A change to the guide or to an event's identity never stops a channel that is still allowed. Only a reason about the channel does (see [revalidate]).
 */
class SportsPlaybackCoordinator(
    private val deps: SportsPlaybackDeps,
    private val scope: CoroutineScope,
    private val diagnostics: SportsPlaybackDiagnostics = SportsPlaybackDiagnostics.Log,
) {
    private val _state = MutableStateFlow(SportsPlaybackState())
    val state: StateFlow<SportsPlaybackState> = _state.asStateFlow()

    private val lock = Any()
    @Volatile private var generation = 0
    @Volatile private var events: (String) -> SportsEvent? = { null }
    private var pending: Job? = null
    private var seq = 0
    private var requestedAt = 0L
    private var lastMode = SportsPlayMode.BEST
    private var lastManual = false
    private var lastReason: RankReason? = null
    private var lastFeedCount = 0
    /** The feed that was playing when a switch began, and what the state looked like then. Cleared once the switch has settled. */
    private var rollbackTo: String? = null
    private var snapshot: SportsPlaybackState? = null
    private var restoring = false
    /** The profile the stream was started under. */
    private var originProfile: String? = null
    private val selectedByEvent = HashMap<String, String>()
    private val playedByEvent = HashMap<String, String>()
    private val watcher: Job
    /** Live TV's state still shows the previous stream for a moment after a request: what it reports counts only once the new stream has been seen starting (or is another channel). */
    private var sawLoading = false
    private var previousChannelId: String? = null
    private var lastPhase: PlaybackPhase? = null

    init {
        watcher = scope.launch { deps.phase.collect { onPhase(it) } }
        scope.launch(kotlinx.coroutines.Dispatchers.Default) { deps.baseRank() }          // warms what the first ranking needs (the device's decoders) off the main thread
    }

    val hasOrigin: Boolean get() = _state.value.origin != null
    val isHeld: Boolean get() = _state.value.held != null

    /** The ViewModel hands over where to look an event up (its loaded events). */
    fun useEvents(lookup: (String) -> SportsEvent?) { events = lookup }

    // ---- ranking (no network, no database)

    fun rankInput(eventId: String): RankInput {
        val base = deps.baseRank()
        return RankInput(selectedByEvent[eventId], playedByEvent[eventId], base.preferredLanguage, base.preferredSourceIds, base.healthyChannelIds, base.deviceDecodes4K)
    }

    /** The ranked feeds for the detail screen and the sentence that explains the best one: the same ranking that Watch Best Feed uses. */
    fun recommendedFor(eventId: String): Pair<List<RankedFeed>, String?> {
        val e = events(eventId) ?: return emptyList<RankedFeed>() to null
        val ranked = SportsFeedRanker.rank(e.feeds, rankInput(eventId))
        return ranked to ranked.firstOrNull()?.let { SportsFeedRanker.explain(it) }
    }

    // ---- requests

    /** Watch Best Feed: the best feed that is allowed right now. */
    fun watch(eventId: String) { launch(eventId, null, SportsPlayMode.BEST) }

    /** A feed the person chose. */
    fun watchFeed(eventId: String, channelId: String) { launch(eventId, channelId, SportsPlayMode.EXACT) }

    /** Another feed of the event now playing, from the player. */
    fun switchTo(channelId: String) { val o = _state.value.origin ?: return; launch(o.eventId, channelId, SportsPlayMode.SWITCH) }

    /** Try Again after a failure. */
    fun retry() { val s = _state.value; val o = s.origin ?: return; val c = s.attemptedChannelId ?: o.channelId; launch(o.eventId, c, SportsPlayMode.SWITCH) }

    private fun launch(eventId: String, channelId: String?, mode: SportsPlayMode) {
        pending?.cancel()
        val gen = generation; val profile = deps.profileId
        val startedAt = deps.nowMs()
        val my = synchronized(lock) { ++seq }
        pending = scope.launch { request(eventId, channelId, mode, gen, profile, startedAt, my) }
    }

    private suspend fun request(eventId: String, channelId: String?, mode: SportsPlayMode, gen: Int, profile: String, startedAt: Long, my: Int) {
        val manual = channelId != null
        fun report(stage: SportsPlayStage, feeds: Int, reason: RankReason?, rejection: PlayRejection? = null, failure: PlayFailure? = null) =
            diagnostics.record(SportsPlaybackReport(stage, mode, feeds, manual, reason, rejection, failure, deps.nowMs() - startedAt))
        report(SportsPlayStage.REQUESTED, 0, null)
        fun reject(r: PlayRejection, feeds: Int) { report(SportsPlayStage.REJECTED, feeds, null, rejection = r); refused(r, my) }

        val event = events(eventId) ?: return reject(PlayRejection.EVENT_GONE, 0)
        val allowed = authorizedFeeds(event, profile, gen)
        if (gen != generation) return reject(PlayRejection.STALE, event.feeds.size)
        if (deps.profileId != profile) return reject(PlayRejection.PROFILE_CHANGED, event.feeds.size)
        val ranked = SportsFeedRanker.rank(allowed.map { it.first }, rankInput(eventId))
        val chosen: RankedFeed? = if (channelId == null) ranked.firstOrNull() else ranked.firstOrNull { it.feed.channelId == channelId }
        if (chosen == null) {
            val why = if (channelId != null && event.feeds.any { it.channelId == channelId }) refusal(event.feeds.first { it.channelId == channelId }, profile) else PlayRejection.NO_FEED
            return reject(why ?: PlayRejection.NO_FEED, event.feeds.size)
        }
        val channel = allowed.first { it.first.channelId == chosen.feed.channelId }.second
        if (gen != generation) return reject(PlayRejection.STALE, event.feeds.size)
        if (deps.profileId != profile) return reject(PlayRejection.PROFILE_CHANGED, event.feeds.size)
        val names = deps.sourceNames()

        synchronized(lock) {
            if (my != seq) return                                                              // a newer request owns the state
            val cur = _state.value
            // While one feed of this event is playing it stays the selected one until the new one is really playing; it is also the feed to go back to if the new one fails.
            val prevPlaying = cur.takeIf { it.status == SportsPlayStatus.PLAYING }?.origin?.takeIf { it.eventId == eventId }?.channelId
            rollbackTo = prevPlaying?.takeIf { it != chosen.feed.channelId }
            snapshot = cur.takeIf { rollbackTo != null }
            restoring = false
            originProfile = profile
            lastMode = mode; lastManual = manual; lastReason = chosen.reason; lastFeedCount = ranked.size; requestedAt = startedAt
            if (manual) selectedByEvent[eventId] = chosen.feed.channelId
            val selected = prevPlaying ?: chosen.feed.channelId
            sawLoading = false; previousChannelId = lastPhase?.channelId
            _state.value = SportsPlaybackState(
                origin = SportsOrigin(eventId, selected, gen), status = SportsPlayStatus.STARTING,
                options = options(ranked, names, selected, ranked.firstOrNull()?.feed?.channelId),
                attemptedChannelId = chosen.feed.channelId, request = my,
            )
        }
        report(SportsPlayStage.ACCEPTED, ranked.size, chosen.reason)
        deps.play(channel) { result -> onStart(my, result) }
    }

    /** The play action's one report for request [my]. An older request's report is ignored. */
    private fun onStart(my: Int, result: PlayStart) {
        synchronized(lock) {
            if (my != seq) return
            val s = _state.value
            when (result) {
                PlayStart.STARTED -> {}
                PlayStart.REJECTED -> {
                    diagnostics.record(SportsPlaybackReport(SportsPlayStage.REJECTED, lastMode, lastFeedCount, lastManual, lastReason, PlayRejection.PLAYER_REFUSED, null, deps.nowMs() - requestedAt))
                    val back = snapshot
                    // Nothing was replaced when a switch is refused: the feed that was playing still is. A refused restoration is the normal failure state. Otherwise nothing plays from Sports.
                    _state.value = when {
                        restoring -> s.copy(status = SportsPlayStatus.FAILED, message = "This feed could not be played.", request = my)
                        back != null -> back.copy(message = NOT_AVAILABLE, request = my)
                        else -> SportsPlaybackState(message = NOT_AVAILABLE, request = my)
                    }
                    rollbackTo = null; snapshot = null; restoring = false
                }
                PlayStart.SUPERSEDED -> {
                    // Something else (not a newer Sports request) took the player: Sports no longer owns the playing channel and must not touch it.
                    _state.value = SportsPlaybackState(request = my)
                    rollbackTo = null; snapshot = null; restoring = false
                }
            }
        }
    }

    /** Every feed of the event that passes the checks right now, with the channel read afresh. */
    private suspend fun authorizedFeeds(event: SportsEvent, profile: String, gen: Int): List<Pair<SportsFeed, Channel>> = SportsAuthorizer.authorizedFeeds(deps, event, profile) { gen == generation }

    private suspend fun refusal(f: SportsFeed, profile: String): PlayRejection? = SportsAuthorizer.refusal(deps, f, profile)

    private suspend fun refusalFor(ch: Channel, profile: String): PlayRejection? = SportsAuthorizer.refusal(deps, ch, profile)

    private fun options(ranked: List<RankedFeed>, names: Map<String, String>, selected: String, rankedBest: String?) = ranked.map { r ->
        val f = r.feed
        SportsFeedOption(
            f.channelId, f.channelName, names[f.sourceId].orEmpty(), f.language, f.languageSource != MetadataSource.PROVIDER, f.quality, f.qualitySource != MetadataSource.PROVIDER,
            f.catchUp, f.channelId == selected, f.channelId == rankedBest, r.deprioritized,
        )
    }

    // ---- what is allowed may have changed

    /**
     * Called after the events were rebuilt (a guide refresh, a refresh the person asked for, a security change). The feed list is rebuilt from what is allowed now.
     *
     * A guide change is not a reason to stop a stream: if the event is gone, or no longer lists the playing channel, but that channel is still allowed, it keeps playing and Sports lets
     * go of it ([held]). Only a reason about the channel itself stops it.
     */
    fun refreshOptions() {
        val o = _state.value.origin ?: return
        val gen = generation; val profile = deps.profileId
        scope.launch {
            val event = events(o.eventId)
            val ranked = event?.let { e -> SportsFeedRanker.rank(authorizedFeeds(e, profile, gen).map { it.first }, rankInput(o.eventId)) }
            if (gen != generation) return@launch
            if (ranked == null || ranked.none { it.feed.channelId == o.channelId }) { settle(o, profile, retain = true); return@launch }
            val names = deps.sourceNames()
            synchronized(lock) { _state.update { it.copy(options = options(ranked, names, it.origin?.channelId ?: o.channelId, ranked.firstOrNull()?.feed?.channelId)) } }
        }
    }

    /**
     * A change to who may see what (the profile, the open library, the adult filter or kids mode, a folder lock, a connection, a hidden channel). Pending requests are dropped and the feed
     * list is emptied. What was started from Sports stops only if the playing channel itself is no longer allowed, or the profile is not the one it was started under; otherwise it keeps
     * playing and Sports lets go of it.
     */
    fun invalidate() {
        synchronized(lock) {
            generation++
            pending?.cancel(); pending = null
            rollbackTo = null; snapshot = null; restoring = false
            selectedByEvent.clear(); playedByEvent.clear()
            _state.update { it.copy(options = emptyList(), suggestedChannelId = null) }
        }
    }

    /** After [invalidate], once the new situation is known: decide whether the stream may go on. */
    fun revalidate() {
        val o = _state.value.origin ?: return
        val profile = deps.profileId
        scope.launch { settle(o, profile, retain = false) }
    }

    /**
     * Decides what becomes of a stream whose event can no longer be shown. A reason about the channel stops it. Otherwise it keeps playing: with [retain] (the guide changed) Sports keeps its
     * embedded player and says so; without it (the content was cleared) the stream is handed to Live TV's embedded player at once. Either way nothing is restarted.
     */
    private suspend fun settle(o: SportsOrigin, profile: String, retain: Boolean) {
        val started = originProfile
        if (started != null && started != profile) { end(); return }                                // the profile policy: a stream does not follow a profile switch
        val ch = deps.channel(o.channelId)
        val allowed = ch != null && refusalFor(ch, profile) == null
        if (!allowed || ch == null) { end(); return }
        synchronized(lock) {
            if (_state.value.origin?.channelId != o.channelId) return
            val playing = _state.value.status == SportsPlayStatus.PLAYING || _state.value.status == SportsPlayStatus.STARTING
            rollbackTo = null; snapshot = null; restoring = false
            _state.value = if (playing) SportsPlaybackState(held = SportsHeld(ch.id, ch.name), handoff = !retain, request = _state.value.request) else SportsPlaybackState(request = _state.value.request)
        }
    }

    /** The person left the event, or Sports: the Sports claim on playback ends and, when asked, the stream stops. */
    fun end(stopPlayback: Boolean = true) {
        synchronized(lock) {
            pending?.cancel(); pending = null
            val had = _state.value.origin != null || _state.value.held != null
            rollbackTo = null; snapshot = null; restoring = false
            _state.value = SportsPlaybackState(request = ++seq)
            if (had && stopPlayback) deps.stop()
        }
    }

    /** The person left the held channel's panel (Back, Close, or "Open in Live TV"): Sports gives the stream up to Live TV's embedded player. */
    fun handOff() { synchronized(lock) { _state.update { if (it.held != null) it.copy(handoff = true) else it } } }

    /** The hand-over was carried out: Sports lets go of the stream without stopping it. True once. */
    fun consumeHandoff(): Boolean = synchronized(lock) { val h = _state.value.handoff; if (h) _state.value = SportsPlaybackState(request = _state.value.request); h }

    /** The person closed the failure message. */
    fun dismissMessage() { _state.update { it.copy(message = null) } }

    // ---- what the player reports back

    private fun refused(r: PlayRejection, my: Int) {
        val text = when (r) {
            PlayRejection.EVENT_GONE -> "This event is no longer listed."
            PlayRejection.STALE, PlayRejection.PROFILE_CHANGED -> "That request is out of date. Try again."
            else -> NOT_AVAILABLE
        }
        synchronized(lock) { if (my == seq) _state.update { it.copy(message = text, request = my) } }
    }

    private fun onPhase(p: PlaybackPhase) {
        var restoreFrom: String? = null
        synchronized(lock) {
            lastPhase = p
            val s = _state.value
            val attempted = s.attemptedChannelId ?: return
            val origin = s.origin ?: return
            if (s.status != SportsPlayStatus.STARTING && s.status != SportsPlayStatus.PLAYING) return
            if (p.kind == PhaseKind.LOADING) { if (s.status == SportsPlayStatus.STARTING) sawLoading = true; return }
            if (s.status != SportsPlayStatus.STARTING && p.kind == PhaseKind.PLAYING) return
            val current = sawLoading || (p.channelId == attempted && attempted != previousChannelId)
            if (s.status == SportsPlayStatus.STARTING && !current) return
            when (p.kind) {
                PhaseKind.PLAYING -> {
                    // The attempted feed, or the same channel on another connection that Live TV's own recovery moved to.
                    playedByEvent[origin.eventId] = attempted
                    val notice = if (restoring) "Could not switch. Returned to the previous feed." else null
                    _state.value = s.copy(origin = origin.copy(channelId = attempted), status = SportsPlayStatus.PLAYING, options = s.options.map { it.copy(current = it.channelId == attempted) }, message = notice, suggestedChannelId = null)
                    diagnostics.record(SportsPlaybackReport(SportsPlayStage.PLAYING, lastMode, lastFeedCount, lastManual, lastReason, null, null, deps.nowMs() - requestedAt))
                    rollbackTo = null; snapshot = null; restoring = false
                }
                PhaseKind.FAILED -> {
                    diagnostics.record(SportsPlaybackReport(SportsPlayStage.FAILED, lastMode, lastFeedCount, lastManual, lastReason, null, p.failure ?: PlayFailure.OTHER, deps.nowMs() - requestedAt))
                    val back = rollbackTo
                    if (back != null && s.status == SportsPlayStatus.STARTING && !restoring) restoreFrom = back
                    else {
                        val next = s.options.firstOrNull { it.channelId != attempted && !it.unsupported }?.channelId ?: s.options.firstOrNull { it.channelId != attempted }?.channelId
                        _state.value = s.copy(status = SportsPlayStatus.FAILED, message = "This feed could not be played.", suggestedChannelId = next)
                        rollbackTo = null; snapshot = null; restoring = false
                    }
                }
                else -> {}
            }
        }
        restoreFrom?.let { restore(it) }
    }

    /** The new feed failed after it replaced the player: start the feed that was playing again, through the same play action. */
    private fun restore(channelId: String) {
        val gen = generation; val profile = deps.profileId
        val my = synchronized(lock) { ++seq }
        pending?.cancel()
        pending = scope.launch {
            val ch = deps.channel(channelId)
            val ok = ch != null && refusalFor(ch, profile) == null && gen == generation && deps.profileId == profile
            if (!ok || ch == null) {
                synchronized(lock) {
                    if (my != seq) return@launch
                    rollbackTo = null; snapshot = null; restoring = false
                    _state.update { it.copy(status = SportsPlayStatus.FAILED, message = "This feed could not be played.") }          // the normal failure state
                }
                return@launch
            }
            synchronized(lock) {
                if (my != seq) return@launch
                val s = _state.value
                rollbackTo = null; restoring = true; lastMode = SportsPlayMode.RESTORE; requestedAt = deps.nowMs()
                sawLoading = false; previousChannelId = lastPhase?.channelId
                _state.value = s.copy(status = SportsPlayStatus.STARTING, attemptedChannelId = channelId, request = my, message = null, suggestedChannelId = null)
            }
            deps.play(ch) { result -> onStart(my, result) }
        }
    }

    private companion object { const val NOT_AVAILABLE = "That feed is not available." }
}
