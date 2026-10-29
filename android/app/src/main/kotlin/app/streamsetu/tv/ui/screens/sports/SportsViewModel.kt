package app.streamsetu.tv.ui.screens.sports

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.SportsPlaybackCoordinator
import app.streamsetu.tv.sports.SportsPlaybackState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Owns what the Sports Hub shows: the loaded events, the selected filter and the open detail. The screen only draws [uiState]; the Navigator only knows which tab is open, what Back does and where
 * the remote was. Nothing here is started by focus: events are loaded when the screen is first used and again only when something that decides them changes.
 *
 *  - A change to who may see what (the open library, the profile, the adult filter or kids mode, a folder lock or relock, the playlists in use, a hidden channel) clears what is on screen at once and
 *    rebuilds it; a result that was started before the change is dropped.
 *  - An ordinary change (the guide was refreshed, the guide time offset changed, Refresh was chosen) keeps the old content on screen while the new is built.
 */
@OptIn(FlowPreview::class)
@HiltViewModel
class SportsViewModel internal constructor(private val deps: SportsDeps, scope: CoroutineScope?, private val debounceMs: Long, private val diagnostics: SportsDiagnostics = SportsDiagnostics.Log, private val playback: SportsPlaybackCoordinator? = null, private val multiview: app.streamsetu.tv.sports.multiview.SportsMultiviewController? = null) : ViewModel() {
    @Inject constructor(c: AppContainer) : this(RealSportsDeps(c), null, 1_500L, SportsDiagnostics.Log, c.sportsPlayback, c.sportsMultiview)

    private val work: CoroutineScope = scope ?: viewModelScope

    /** What was loaded, and the state of loading it. Content is the part that the privacy rules clear. */
    private data class Loaded(
        val events: List<SportsEvent> = emptyList(), val revision: String = "", val sourceNames: Map<String, String> = emptyMap(), val hasGuide: Boolean = true,
        val loading: Boolean = true, val refreshing: Boolean = false, val error: String? = null,
    )

    private val loaded = MutableStateFlow(Loaded())
    private val selected = MutableStateFlow<Sport?>(null)
    private val detailId = MutableStateFlow<String?>(null)

    /** Where the list was scrolled, kept here because the screen is not composed while another tab is open. */
    var scrollIndex = 0; var scrollOffset = 0
    private var currentScope: SportsScope? = null
    private var generation = 0
    private var loadJob: Job? = null
    @Volatile var loadCount = 0; private set

    private val mvNote = MutableStateFlow<String?>(null)
    private class Extras(val playback: SportsPlaybackState, val multiviewCount: Int, val note: String?)
    private val extras = combine(
        playback?.state ?: kotlinx.coroutines.flow.flowOf(SportsPlaybackState()),
        multiview?.selection?.state ?: kotlinx.coroutines.flow.flowOf(app.streamsetu.tv.sports.multiview.SelectionState()),
        mvNote,
    ) { pb, sel, note -> Extras(pb, sel.entries.size, note) }

    val uiState: StateFlow<SportsHubUiState> = combine(loaded, selected, detailId, deps.minutes, extras) { l, sel, detail, now, x -> build(l, sel, detail, now, x.playback, x.multiviewCount, x.note) }
        .flowOn(Dispatchers.Default)
        .stateIn(work, SharingStarted.WhileSubscribed(5_000), SportsHubUiState(loading = true, nowMs = deps.now()))

    init {
        playback?.useEvents { id -> loaded.value.events.firstOrNull { it.id == id } }
        multiview?.selection?.useEvents { loaded.value.events }
        work.launch { deps.scope.collect { s -> onScope(s) } }
        work.launch { deps.dataSignals.debounce(debounceMs).collect { if (currentScope != null) startLoad(clear = false) } }
    }

    // ---- what the screen can ask for

    /** Applies a filter that is already loaded; nothing is queried. */
    fun select(sport: Sport?) { selected.value = sport }
    fun openDetail(id: String) { if (detailId.value != id) { playback?.end(); mvNote.value = null }; detailId.value = id }
    /** Closing the detail ends the Sports playback that belongs to it. */
    fun closeDetail() {
        // A channel that outlived its event is not stopped by leaving the panel: Sports gives it up to Live TV's embedded player.
        if (playback?.state?.value?.held != null) { playback.handOff(); return }
        detailId.value = null; playback?.end()
    }
    /** Stop on the held channel's panel. */
    fun stopHeld() { detailId.value = null; playback?.end() }
    /** The hand-over to Live TV was carried out. */
    fun completeHandoff() { detailId.value = null; playback?.consumeHandoff() }

    // ---- playback (nothing here is called by focus; each is the person pressing OK)

    fun watchBest() { detailId.value?.let { playback?.watch(it) } }
    fun watchFeed(channelId: String) { detailId.value?.let { playback?.watchFeed(it, channelId) } }
    fun retryPlayback() { playback?.retry() }
    /** Back to Event, leaving the detail open; and leaving Sports. Both release the stream that Sports started. */
    fun stopPlayback() { playback?.end() }

    // ---- Multiview (each is the person choosing; nothing starts a stream)

    /** Adds the open event's recommended feed (or [channelId]) to the Multiview list. */
    fun addToMultiview(channelId: String? = null) {
        val id = detailId.value ?: return
        val m = multiview ?: return
        work.launch {
            val r = m.selection.add(id, channelId)
            mvNote.value = if (r is app.streamsetu.tv.sports.multiview.SelectionResult.Done) "Added to Multiview (${m.selection.state.value.entries.size} of ${m.selection.state.value.limit}). Open Multiview to start." else m.selection.state.value.message
        }
    }
    /** Playing a Sports stream and a Multiview cannot share the decoders: the stream is released before the Multiview opens. */
    fun beforeMultiview() { playback?.end() }
    fun dismissPlaybackMessage() { playback?.dismissMessage() }
    /** The person chose Refresh (or Retry): the old content stays until the new is ready. */
    fun refresh() { if (currentScope != null) startLoad(clear = false) }
    /** The screen was entered again; the events are refreshed in the background only if they are old. */
    fun onEntered(maxAgeMs: Long = 30 * 60_000L) { if (currentScope != null && deps.now() - loadedAt > maxAgeMs && !loaded.value.loading && !loaded.value.refreshing) startLoad(clear = false) }

    // ---- loading

    private var loadedAt = 0L

    private fun onScope(s: SportsScope) {
        val first = currentScope == null
        val changed = currentScope != s
        currentScope = s
        if (!changed) return
        if (!first) playback?.invalidate()                 // a pending play request or open feed list from before the change is dropped
        startLoad(clear = !first)                          // a change to who may see what: clear at once (the first value has nothing to clear)
    }

    private fun startLoad(clear: Boolean) {
        val scope = currentScope ?: return
        loadJob?.cancel()
        val gen = ++generation
        if (clear) { loaded.value = Loaded(loading = true); detailId.value = null; playback?.revalidate() }          // the stream goes on only if its channel is still allowed (see SportsPlaybackCoordinator.revalidate)
        else loaded.update { it.copy(refreshing = true, error = null) }
        loadJob = work.launch {
            val startedAt = System.nanoTime()
            fun ms() = (System.nanoTime() - startedAt) / 1_000_000L
            try {
                val now = deps.now()
                val from = now / 900_000L * 900_000L - 4 * 3_600_000L
                val names = deps.sourceNames(); val hasGuide = deps.hasGuide()
                loadCount++
                val r = deps.load(scope, from, from + 72 * 3_600_000L)
                if (gen != generation) return@launch                                              // started before a newer request: dropped
                loadedAt = deps.now()
                loaded.value = Loaded(events = r.events, revision = r.revision, sourceNames = names, hasGuide = hasGuide, loading = false)
                diagnostics.record(SportsLoadReport.of(r.events, now, deps.zone, scope.sourceIds.size, ms(), r.cacheHit))
                playback?.refreshOptions()                                                        // a feed that is no longer allowed leaves the list; a playing one that is not is let go
            } catch (e: CancellationException) {
                diagnostics.record(SportsLoadReport.failed(SportsLoadOutcome.CANCELLED, null, scope.sourceIds.size, ms()))
                throw e
            } catch (e: Exception) {
                diagnostics.record(SportsLoadReport.failed(SportsLoadOutcome.ERROR, e, scope.sourceIds.size, ms()))
                if (gen == generation) { loadedAt = deps.now(); loaded.update { it.copy(loading = false, refreshing = false, error = "The sports events could not be loaded.") } }          // Retry is the person's choice; entering the screen does not retry by itself
            }
        }
    }

    // ---- state (computed here, never in a composable)

    private fun build(l: Loaded, sel: Sport?, detail: String?, now: Long, pb: SportsPlaybackState, mvCount: Int, note: String?): SportsHubUiState {
        val play = if (detail != null && playback != null) {
            val (ranked, why) = playback.recommendedFor(detail)
            SportsDetailPlay(ranked.map { it.feed.channelId }, ranked.filter { it.deprioritized }.map { it.feed.channelId }.toSet(), why, pb)
        } else SportsDetailPlay()
        val r = SportsSections.build(l.events, now, deps.zone, sel, detail, l.sourceNames, play = play)
        val message = when {
            l.loading -> null
            r.live.isEmpty() && r.soon.isEmpty() && r.today.isEmpty() && r.upcoming.isEmpty() && l.error != null -> SportsHubMessage.Error(l.error)
            l.events.none { it.endMs > now } && !l.hasGuide -> SportsHubMessage.NoGuide
            l.events.none { it.endMs > now } -> SportsHubMessage.NoSports
            else -> null
        }
        return SportsHubUiState(l.loading, l.refreshing, r.selected, r.filters, r.live, r.soon, r.today, r.upcoming, r.detail?.copy(multiviewNote = note) ?: pb.held?.takeIf { !pb.handoff }?.let { SportsSections.heldDetail(it.channelName) }, message, l.revision, now, pb.handoff, mvCount)
    }
}
