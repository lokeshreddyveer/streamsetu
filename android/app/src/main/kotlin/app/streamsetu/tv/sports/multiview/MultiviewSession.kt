package app.streamsetu.tv.sports.multiview

import androidx.compose.runtime.Immutable
import app.streamsetu.core.model.Channel
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What a tile's player tells the session. Fixed words only: a player message can carry an address and never gets this far. */
sealed interface TileEvent {
    data object Buffering : TileEvent
    data object Ready : TileEvent
    data class Failed(val failure: TileFailure, val decoderAllocation: Boolean) : TileEvent
}

/** The address and request details of one stream. Built and used only below the screen; never part of any UI state. */
class TileRequest(val url: String, val headers: Map<String, String>, val maxWidth: Int, val maxHeight: Int)

/** One tile's player. The real one wraps the same `ExoEngine` the single player uses. */
interface TileEngine {
    var onEvent: (TileEvent) -> Unit
    fun load(request: TileRequest)
    fun setVolume(volume: Float)
    /** Captions belong to the tile that has the sound. */
    fun setCaptions(enabled: Boolean)
    fun stop()
    /** Frees the decoder, the audio output and the network connection at once. */
    fun release()
    /** The picture, for the screen to place. Null for a test double. */
    fun view(context: android.content.Context): android.view.View?
}

/** Everything the session needs from the app, so a test can supply it and count every call. */
interface MultiviewDeps : SportsAuthorization {
    /** A new player, or null when none can be made. */
    fun createEngine(): TileEngine?
    /** The address and headers for a channel, by the same resolver Live TV uses. Slow and possibly networked: only ever called off the main thread. */
    suspend fun resolve(channel: Channel): TileRequest?
    fun nowMs(): Long
}

enum class TileStatus { QUEUED, STARTING, PLAYING, FAILED, NO_DECODER }

/** One tile, as the screen draws it: nothing else is needed and no address is in it. Each tile has its own value, so a change to one does not redraw the others. */
@Immutable
data class TileUi(
    val id: Long,
    val channelId: String,
    val feedLabel: String,
    /** The event this tile was started from, or null once the guide no longer lists it (the channel keeps playing). */
    val eventTitle: String?,
    val eventId: String?,
    val status: TileStatus,
    val failure: TileFailure?,
    val audio: Boolean,
    val message: String?,
    val switching: Boolean,
)

enum class MultiviewNotice { NOT_ENOUGH, ONE_LEFT, NO_DECODER }

@Immutable
data class MultiviewState(val tiles: List<TileUi> = emptyList(), val limit: Int = 2, val notice: MultiviewNotice? = null, val message: String? = null) {
    val active: Boolean get() = tiles.isNotEmpty()
}

/**
 * Plays two to four feeds at once, one tile per player.
 *
 *  - Start: every entry is checked again; a stale or restricted one is dropped before anything plays; the primary starts first and the others follow one at a time, each when the one before has
 *    answered. A tile that fails stays in its place with its own choices; the others go on.
 *  - Only one tile has sound; the others are silent at the player. Moving the sound changes volumes and never reloads a picture.
 *  - A change of feed in a tile snapshots the current feed, checks and starts the new one in the same player, and if that fails starts the old one again. It never moves to another feed by itself.
 *  - A change to who may see what checks every tile on its own: only a tile that is no longer allowed is removed, and requests from the old situation are cancelled.
 *  - A guide change that drops an event only detaches the tile from it.
 *  - Every callback carries its tile and that tile's generation, so a late one cannot touch a tile that has since been replaced.
 *
 * All changes happen on [scope] (one thread); stream addresses are resolved on [io].
 */
class MultiviewSession(
    private val deps: MultiviewDeps,
    private val capability: MultiviewCapability,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val diagnostics: MultiviewDiagnostics = MultiviewDiagnostics.Log,
) {
    private class Tile(val id: Long, var entry: MultiviewEntry) {
        var engine: TileEngine? = null
        var channel: Channel? = null
        var status = TileStatus.QUEUED
        var failure: TileFailure? = null
        var message: String? = null
        var gen = 0
        var previous: MultiviewEntry? = null
        var restoring = false
        var detached = false
        var requestedAt = 0L
        var reported = false
        var loaded = false
        var settled: CompletableDeferred<Unit>? = null
    }

    private val tiles = ArrayList<Tile>()          // slot order: index 0 is the primary
    private var nextId = 1L
    private var audioId: Long? = null
    private var generation = 0
    private var startJob: Job? = null
    private var notice: MultiviewNotice? = null
    private var sessionMessage: String? = null
    private var startedProfile: String? = null
    private var startedAt = 0L
    private var requested = 0

    private val _state = MutableStateFlow(MultiviewState(limit = TileLimitPolicy.MAX))
    val state: StateFlow<MultiviewState> = _state.asStateFlow()

    @Volatile private var sources: List<String> = emptyList()
    /** One entry per connection the tiles are using (or about to use), for the recording capacity check. Read from any thread. */
    fun activeSources(): List<String> = sources

    private fun publish() {
        sources = tiles.filter { it.status != TileStatus.FAILED && it.status != TileStatus.NO_DECODER }.map { it.entry.sourceId }
        val t = tiles.map { it.toUi() }
        _state.value = MultiviewState(t, capability.usableLimit(), notice, sessionMessage)
    }

    private fun Tile.toUi() = TileUi(id, entry.channelId, entry.feedLabel, if (detached || entry.eventTitle.isBlank()) null else entry.eventTitle, if (detached || entry.eventId.isBlank()) null else entry.eventId, status, failure, id == audioId, message, previous != null && !restoring)

    private fun report(stage: MultiviewStage, started: Int = tiles.count { it.status == TileStatus.PLAYING }, failure: TileFailure? = null, since: Long = startedAt) =
        diagnostics.record(MultiviewReport(stage, requested, capability.usableLimit(), started, failure, deps.nowMs() - since, capability.deviceFacts().memoryClassMb))

    private val Tile.working get() = status == TileStatus.PLAYING || status == TileStatus.STARTING

    // ---- starting

    /** Who the tiles belong to: the screen that started them. A screen that leaves releases only what is still its own. */
    private var owner: Any? = null
    private val queue = ArrayDeque<Tile>()
    private var runner: Job? = null

    /**
     * Begins a Multi-View of [entries], first checking each one again. [minimum] is how many valid feeds make one (two for a Sports Multiview, one for the ordinary Multi-View that starts with the
     * channel that was playing and grows). Whatever another screen had running is released first: there is one session and so never two at once.
     */
    fun start(entries: List<MultiviewEntry>, minimum: Int = 2, owner: Any? = null) {
        generation++
        startJob?.cancel(); runner?.cancel(); queue.clear()
        val gen = generation
        startJob = scope.launch { startAll(entries, minimum, owner, gen) }
    }

    /** Adds one picture to a running Multi-View, up to the number this device can show. It starts after the ones before it have answered. */
    fun add(entry: MultiviewEntry, owner: Any? = null) {
        scope.launch {
            val limit = capability.usableLimit()
            if (tiles.any { it.entry.channelId == entry.channelId }) { sessionMessage = "That channel is already in the Multi-View."; publish(); return@launch }
            if (tiles.size >= limit) { sessionMessage = "This device can show $limit view${if (limit == 1) "" else "s"} at once."; publish(); return@launch }
            val profile = deps.profileId; val gen = generation
            val ch = deps.channel(entry.channelId)
            val ok = ch != null && ch.sourceId == entry.sourceId && SportsAuthorizer.refusal(deps, ch, profile) == null && deps.profileId == profile
            if (gen != generation) return@launch
            if (!ok || ch == null) { sessionMessage = "That feed is not available."; publish(); return@launch }
            if (tiles.isEmpty()) { this@MultiviewSession.owner = owner; startedProfile = profile; startedAt = deps.nowMs(); requested = 0 }
            requested++
            sessionMessage = null
            val t = Tile(nextId++, entry).also { it.channel = ch }
            tiles += t
            if (audioId == null) audioId = t.id
            publish(); enqueue(t, gen)
        }
    }

    private fun enqueue(t: Tile, gen: Int) {
        queue.addLast(t)
        if (runner?.isActive == true) return
        runner = scope.launch {
            while (queue.isNotEmpty()) {
                if (gen != generation) return@launch
                val next = queue.removeFirst()
                if (next in tiles && next.status == TileStatus.QUEUED) startTile(next, gen)
            }
        }
    }

    private suspend fun startAll(entries: List<MultiviewEntry>, minimum: Int, newOwner: Any?, gen: Int) {
        val profile = deps.profileId
        val began = deps.nowMs()
        val good = ArrayList<Pair<MultiviewEntry, Channel>>()
        for (e in entries) {
            val ch = deps.channel(e.channelId)
            if (gen != generation) return
            if (ch != null && ch.sourceId == e.sourceId && SportsAuthorizer.refusal(deps, ch, profile) == null) good += e to ch
        }
        if (gen != generation || deps.profileId != profile) return
        val use = good.take(capability.usableLimit())
        if (use.size < minimum) {                                                                  // stale or restricted entries were rejected before anything changed in playback
            requested = entries.size; startedAt = began; report(MultiviewStage.REQUESTED)
            notice = MultiviewNotice.NOT_ENOUGH; sessionMessage = if (good.size < entries.size) "Some feeds are no longer available." else "A Multi-View needs two feeds."; publish(); return
        }
        releaseAll(); notice = null; sessionMessage = null
        owner = newOwner
        startedAt = began; requested = entries.size; startedProfile = profile
        report(MultiviewStage.REQUESTED)
        if (use.isEmpty()) { publish(); return }
        for ((e, ch) in use) tiles += Tile(nextId++, e).also { it.channel = ch }
        audioId = tiles.first().id
        publish()
        for (t in tiles.toList()) queue.addLast(t)
        runner?.cancel()
        runner = scope.launch {
            while (queue.isNotEmpty()) {
                if (gen != generation) return@launch
                val next = queue.removeFirst()
                if (next in tiles && next.status == TileStatus.QUEUED) startTile(next, gen)
            }
        }
    }

    /** Starts one tile and returns when its player has answered (a picture, a wait, or a failure), so the next decoder is not asked for until this one has been. */
    private suspend fun startTile(t: Tile, gen: Int) {
        t.status = TileStatus.STARTING; t.failure = null; t.message = null; t.requestedAt = deps.nowMs(); t.reported = false; t.loaded = false
        val answered = CompletableDeferred<Unit>().also { t.settled = it }
        publish()
        val engine = t.engine ?: deps.createEngine()?.also { e ->
            t.engine = e
            val tid = t.id
            e.onEvent = { ev -> scope.launch { onEvent(tid, ev) } }
        }
        if (engine == null) { allocationFailed(t); answered.complete(Unit); return }
        applyAudio(t)
        val ch = t.channel
        val request = if (ch == null) null else withContext(io) { deps.resolve(ch) }
        if (gen != generation || t !in tiles) { answered.complete(Unit); return }
        if (request == null) { fail(t, TileFailure.UNAVAILABLE); answered.complete(Unit); return }
        val cap = TileVideoCap.forCount(tiles.size)
        engine.load(TileRequest(request.url, request.headers, cap.first, cap.second)); t.loaded = true
        answered.await()
    }

    private fun onEvent(tileId: Long, ev: TileEvent) {
        val t = tiles.firstOrNull { it.id == tileId } ?: return                                    // removed: a late callback changes nothing (its player was also cut off from the session on release)
        when (ev) {
            TileEvent.Buffering -> { if (t.status != TileStatus.PLAYING) t.status = TileStatus.STARTING; t.settled?.complete(Unit) }
            TileEvent.Ready -> {
                t.status = TileStatus.PLAYING; t.failure = null
                val first = !t.reported; t.reported = true
                when {
                    t.restoring -> { t.message = "Could not switch. Returned to the previous feed."; t.restoring = false; t.previous = null; report(MultiviewStage.FEED_RESTORED, since = t.requestedAt) }
                    t.previous != null -> { t.previous = null; t.message = null; report(MultiviewStage.FEED_SWITCHED, since = t.requestedAt) }
                    first -> report(MultiviewStage.TILE_STARTED)
                }
                t.settled?.complete(Unit)
            }
            is TileEvent.Failed -> onFailed(t, ev)
        }
        publish()
    }

    private fun onFailed(t: Tile, ev: TileEvent.Failed) {
        t.settled?.complete(Unit)
        val back = t.previous
        if (back != null && !t.restoring) { restore(t, back); return }
        if (ev.decoderAllocation) { allocationFailed(t); return }
        fail(t, ev.failure)
    }

    private fun fail(t: Tile, failure: TileFailure) {
        t.status = TileStatus.FAILED; t.failure = failure; t.previous = null; t.restoring = false
        t.message = "This feed could not be played"
        report(MultiviewStage.TILE_FAILED, failure = failure)
        publish()
    }

    /** A decoder could not be allocated for this tile. The working tiles stay; this device is not asked for that many again this session. */
    private fun allocationFailed(t: Tile) {
        val working = tiles.count { it !== t && it.status == TileStatus.PLAYING }
        capability.noteAllocationFailure(working)
        t.status = TileStatus.NO_DECODER; t.failure = TileFailure.NO_DECODER; t.previous = null; t.restoring = false
        t.engine?.let { e -> e.onEvent = {}; runCatching { e.stop(); e.release() } }; t.engine = null; t.gen++
        t.message = "This device cannot play another video at the same time."
        notice = MultiviewNotice.NO_DECODER
        report(MultiviewStage.ALLOCATION_FAILED, started = working, failure = TileFailure.NO_DECODER)
        publish()
    }

    private fun applyAudio(t: Tile) {
        val on = t.id == audioId
        t.engine?.setVolume(if (on) 1f else 0f); t.engine?.setCaptions(on)
    }

    // ---- sound

    /** Moves the sound to this tile. Pictures are not touched. */
    fun listenHere(id: Long) {
        scope.launch {
            val t = tiles.firstOrNull { it.id == id } ?: return@launch
            if (audioId == id) return@launch
            val at = deps.nowMs()
            audioId = id
            tiles.forEach { applyAudio(it) }
            publish(); report(MultiviewStage.AUDIO_CHANGED, since = at)
        }
    }

    // ---- layout

    /** The tile takes the first slot (the large one in a three-tile layout). Its picture is moved, never rebuilt, and the sound stays where it is. */
    fun makePrimary(id: Long) {
        scope.launch {
            val i = tiles.indexOfFirst { it.id == id }
            if (i <= 0) return@launch
            val at = deps.nowMs()
            val order = MultiviewLayout.makePrimary(tiles.toList(), i)
            tiles.clear(); tiles.addAll(order)
            publish(); report(MultiviewStage.PRIMARY_CHANGED, since = at)
        }
    }

    // ---- removing and retrying

    fun remove(id: Long) { scope.launch { removeNow(id) } }

    private fun removeNow(id: Long) {
        val i = tiles.indexOfFirst { it.id == id }
        if (i < 0) return
        val t = tiles.removeAt(i)
        release(t)
        if (audioId == id) { audioId = (tiles.firstOrNull { it.status == TileStatus.PLAYING } ?: tiles.firstOrNull())?.id; tiles.forEach { applyAudio(it) } }
        notice = when { tiles.isEmpty() -> null; tiles.size < 2 -> MultiviewNotice.ONE_LEFT; tiles.any { it.status == TileStatus.NO_DECODER } -> MultiviewNotice.NO_DECODER; else -> null }
        report(MultiviewStage.TILE_REMOVED)
        publish()
    }

    /** Try Again on a failed tile. */
    fun retry(id: Long) {
        scope.launch {
            val t = tiles.firstOrNull { it.id == id } ?: return@launch
            val gen = generation
            if (!reauthorize(t, t.entry)) { removeNow(id); return@launch }
            t.gen++; t.previous = null; t.restoring = false
            if (t.status == TileStatus.NO_DECODER) { notice = null }
            val e = t.engine; if (e != null) runCatching { e.stop() }
            startTile(t, gen)
        }
    }

    /** "Use Two Views": the working tiles up to [count] stay, the rest are removed. */
    fun useAtMost(count: Int) {
        scope.launch {
            val keep = (tiles.filter { it.status == TileStatus.PLAYING } + tiles.filter { it.status != TileStatus.PLAYING }).take(count).map { it.id }.toSet()
            tiles.map { it.id }.filter { it !in keep }.forEach { removeNow(it) }
            notice = if (tiles.size < 2) MultiviewNotice.ONE_LEFT else null
            publish()
        }
    }

    // ---- changing a feed (Phase 3's safe switch, per tile)

    /** Replaces this tile's feed (another feed of the event, or another event) in the same player. */
    fun replace(id: Long, entry: MultiviewEntry) {
        scope.launch {
            val t = tiles.firstOrNull { it.id == id } ?: return@launch
            val gen = generation
            if (tiles.any { it !== t && it.entry.channelId == entry.channelId }) { t.message = "That channel is already in the Multi-View."; publish(); return@launch }
            val profile = deps.profileId
            val ch = deps.channel(entry.channelId)
            val ok = ch != null && ch.sourceId == entry.sourceId && SportsAuthorizer.refusal(deps, ch, profile) == null && deps.profileId == profile
            if (gen != generation || t !in tiles) return@launch
            if (!ok || ch == null) { t.message = "That feed is not available."; publish(); return@launch }      // nothing was touched: the tile goes on
            val before = t.entry
            t.previous = before; t.restoring = false; t.entry = entry; t.channel = ch; t.detached = false; t.gen++
            t.status = TileStatus.STARTING; t.failure = null; t.message = null; t.requestedAt = deps.nowMs(); t.reported = true
            publish()
            loadInto(t, gen)
        }
    }

    private suspend fun loadInto(t: Tile, gen: Int) {
        val ch = t.channel; val e = t.engine
        if (ch == null || e == null) { fail(t, TileFailure.UNAVAILABLE); return }
        val request = withContext(io) { deps.resolve(ch) }
        if (gen != generation || t !in tiles) return
        if (request == null) { onFailed(t, TileEvent.Failed(TileFailure.UNAVAILABLE, false)); publish(); return }
        val cap = TileVideoCap.forCount(tiles.size)
        e.load(TileRequest(request.url, request.headers, cap.first, cap.second)); t.loaded = true
    }

    /** The new feed failed: the feed that was playing starts again, checked first. Nothing else is tried. */
    private fun restore(t: Tile, back: MultiviewEntry) {
        val gen = generation
        scope.launch {
            val ch = deps.channel(back.channelId)
            val ok = ch != null && ch.sourceId == back.sourceId && SportsAuthorizer.refusal(deps, ch, deps.profileId) == null
            if (gen != generation || t !in tiles) return@launch
            if (!ok || ch == null) { fail(t, TileFailure.UNAVAILABLE); return@launch }
            t.entry = back; t.channel = ch; t.restoring = true; t.gen++; t.status = TileStatus.STARTING; t.requestedAt = deps.nowMs(); t.message = null
            publish()
            loadInto(t, gen)
        }
    }

    private suspend fun reauthorize(t: Tile, e: MultiviewEntry): Boolean {
        val profile = deps.profileId
        val ch = deps.channel(e.channelId)
        val ok = ch != null && ch.sourceId == e.sourceId && SportsAuthorizer.refusal(deps, ch, profile) == null
        if (ok) t.channel = ch
        return ok
    }

    // ---- who may see what

    /**
     * After a change to the profile, the library, a lock, a hidden channel, the adult filter or a connection: requests from before it are cancelled, every tile is checked on its own, and only
     * the ones no longer allowed are removed (all of them if the profile is not the one the Multi-View started under). Tiles still waiting to start continue if they are allowed.
     */
    fun revalidate() {
        generation++
        startJob?.cancel(); runner?.cancel(); queue.clear()
        val gen = generation
        scope.launch {
            val profile = deps.profileId
            if (startedProfile != null && startedProfile != profile) { stopAllNow(); return@launch }
            for (t in tiles.toList()) {
                val ok = reauthorize(t, t.entry)
                if (gen != generation) return@launch
                if (!ok) removeNow(t.id)
            }
            for (t in tiles) { t.previous = null; t.restoring = false; if (t.status == TileStatus.STARTING && !t.loaded) t.status = TileStatus.QUEUED }          // a switch or start from the old situation is dropped
            queue.clear(); runner?.cancel()
            for (t in tiles.toList()) if (t.status == TileStatus.QUEUED) enqueue(t, gen)
            publish()
        }
    }

    /** The guide no longer lists these events: their tiles let go of them and keep playing. */
    fun detachMissing(exists: (String) -> Boolean) {
        scope.launch { var any = false; for (t in tiles) if (!t.detached && !exists(t.entry.eventId)) { t.detached = true; any = true }; if (any) publish() }
    }

    // ---- ending

    /** Ends the Multi-View. With an [owner], only if the tiles are still that screen's: a screen leaving after another one took over must not stop the new one. */
    fun stopAll(owner: Any? = null) { if (owner != null && this.owner !== owner && tiles.isNotEmpty()) return; generation++; startJob?.cancel(); runner?.cancel(); queue.clear(); scope.launch { stopAllNow() } }

    private fun stopAllNow() { releaseAll(); notice = null; sessionMessage = null; report(MultiviewStage.STOPPED, started = 0); publish() }

    private fun releaseAll() { tiles.toList().forEach { release(it) }; tiles.clear(); queue.clear(); audioId = null; owner = null }

    private fun release(t: Tile) {
        t.gen++
        t.settled?.complete(Unit)
        t.engine?.let { e -> e.onEvent = {}; runCatching { e.stop(); e.release() } }
        t.engine = null; t.channel = null
    }

    /** The picture of a tile, for the screen to place. The player keeps the same view for its whole life, so a tile that moves is never rebuilt. */
    fun viewFor(id: Long, context: android.content.Context): android.view.View? = tiles.firstOrNull { it.id == id }?.engine?.view(context)

    /** Engines held right now (for the resource tests). */
    fun engineCount(): Int = tiles.count { it.engine != null }
}
