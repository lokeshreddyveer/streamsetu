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
import kotlinx.coroutines.flow.first
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
class SportsViewModel internal constructor(private val deps: SportsDeps, scope: CoroutineScope?, private val debounceMs: Long, private val diagnostics: SportsDiagnostics = SportsDiagnostics.Log, private val playback: SportsPlaybackCoordinator? = null, private val multiview: app.streamsetu.tv.sports.multiview.SportsMultiviewController? = null,
    private val follows: app.streamsetu.tv.sports.personal.SportsFollowService? = null, private val reminders: app.streamsetu.tv.sports.personal.SportsReminderService? = null,
    private val recordings: app.streamsetu.tv.sports.recording.SportsRecordingService? = null) : ViewModel() {
    @Inject constructor(c: AppContainer) : this(RealSportsDeps(c), null, 1_500L, SportsDiagnostics.Log, c.sportsPlayback, c.sportsMultiview, c.sportsFollows, c.sportsReminders, c.sportsRecordings)

    private val work: CoroutineScope = scope ?: viewModelScope

    /** What was loaded, and the state of loading it. Content is the part that the privacy rules clear. */
    private data class Loaded(
        val events: List<SportsEvent> = emptyList(), val revision: String = "", val sourceNames: Map<String, String> = emptyMap(), val hasGuide: Boolean = true,
        val loading: Boolean = true, val refreshing: Boolean = false, val error: String? = null,
        val identities: app.streamsetu.tv.sports.discovery.IdentityIndex = app.streamsetu.tv.sports.discovery.IdentityIndex.EMPTY,
        /** The context epoch this was made under (see [epoch]). */
        val epoch: Int = 0,
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
    private val mySports = MutableStateFlow(false)
    private val managing = MutableStateFlow(false)
    private val personalNote = MutableStateFlow<String?>(null)
    private class Personal(val follows: app.streamsetu.tv.sports.personal.FollowSet, val reminders: List<app.streamsetu.core.data.db.SportsReminderEntity>, val my: Boolean, val manage: Boolean, val note: String?)
    private val abilities = MutableStateFlow<EventAbilities?>(null)
    private val panel = MutableStateFlow<RecordPanelUi?>(null)
    private class Recs(val rows: List<app.streamsetu.core.data.db.SportsRecordingEntity>, val abilities: EventAbilities?, val panel: RecordPanelUi?)
    private data class Hist(val key: String, val events: List<SportsEvent>, val loading: Boolean, val epoch: Int = 0) { companion object { val NONE = Hist("", emptyList(), false) } }
    /**
     * Everything that is drawn is made under one context epoch. A change to who may see what (profile, library, restriction, lock, hidden channel, playlists) raises [epoch] in one synchronous write, and
     * from that very next state anything made under an earlier epoch (events, a page, its Catch-Up, the detail) is not drawn and cannot be acted on; rebuilding then starts under the new one.
     */
    private class Nav(val pages: List<app.streamsetu.tv.sports.discovery.PageRef>, val history: Hist, val fromSearch: Boolean, val notice: String?, val epoch: Int, val pagesEpoch: Int)
    private val pages = MutableStateFlow<List<app.streamsetu.tv.sports.discovery.PageRef>>(emptyList())
    private val epoch = MutableStateFlow(0)
    @Volatile private var pagesEpoch = 0
    private val history = MutableStateFlow(Hist.NONE)
    private val fromSearch = MutableStateFlow(false)
    private val linkNotice = MutableStateFlow<String?>(null)
    private var historyJob: Job? = null
    private val historyCache = LinkedHashMap<String, List<SportsEvent>>()
    /** Counts only; replaced by a test to read them. */
    /** How many times a page or the My Sports board was built (a test reads it: moving the remote must build none). */
    /** How many Catch-Up lookups have finished (answered, failed or found nothing to ask for); a test waits on it instead of on time. */
    internal val historySettled = java.util.concurrent.atomic.AtomicInteger()
    /** How many state builds ran on the main thread (must stay 0: building is `flowOn(Default)`). */
    internal val buildsOnMain = java.util.concurrent.atomic.AtomicInteger()
    internal val discoveryBuilds = java.util.concurrent.atomic.AtomicInteger()
    internal var discovery: app.streamsetu.tv.sports.discovery.DiscoveryDiagnostics = app.streamsetu.tv.sports.discovery.DiscoveryDiagnostics.Log
    private class Extras(val playback: SportsPlaybackState, val multiviewCount: Int, val note: String?, val personal: Personal, val recs: Recs, val nav: Nav)
    private val extras = combine(
        combine(
            playback?.state ?: kotlinx.coroutines.flow.flowOf(SportsPlaybackState()),
            multiview?.selection?.state ?: kotlinx.coroutines.flow.flowOf(app.streamsetu.tv.sports.multiview.SelectionState()),
            mvNote,
        ) { pb, sel, note -> Triple(pb, sel.entries.size, note) },
        combine(
            follows?.follows ?: kotlinx.coroutines.flow.flowOf(app.streamsetu.tv.sports.personal.FollowSet.NONE),
            reminders?.reminders ?: kotlinx.coroutines.flow.flowOf(emptyList()),
            mySports, managing, personalNote,
        ) { f, r, my, m, n -> Personal(f, r, my, m, n) },
        combine(recordings?.recordings ?: kotlinx.coroutines.flow.flowOf(emptyList()), abilities, panel) { rows, ab, pn -> Recs(rows, ab, pn) },
        combine(pages, history, fromSearch, linkNotice, epoch) { pg, h, fs, n, ep -> Nav(pg, h, fs, n, ep, pagesEpoch) },
    ) { a, p, rc, nv -> Extras(a.first, a.second, a.third, p, rc, nv) }

    val uiState: StateFlow<SportsHubUiState> = combine(loaded, selected, detailId, deps.minutes, extras) { l, sel, detail, now, x -> build(l, sel, detail, now, x) }
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
    fun select(sport: Sport?) { mySports.value = false; selected.value = sport; linkNotice.value = null; refreshHistory() }
    /** My Sports: what the active profile follows, from the events already loaded. */
    fun selectMy() { mySports.value = true; linkNotice.value = null; refreshHistory() }
    fun openDetail(id: String) { linkNotice.value = null; if (detailId.value != id) { playback?.end(); mvNote.value = null; personalNote.value = null; abilities.value = null; panel.value = null }; detailId.value = id; refreshAbilities(id) }
    /** Closing the detail ends the Sports playback that belongs to it. */
    fun closeDetail(): Boolean {
        // A channel that outlived its event is not stopped by leaving the panel: Sports gives it up to Live TV's embedded player.
        if (playback?.state?.value?.held != null) { playback.handOff(); return false }
        detailId.value = null; panel.value = null; abilities.value = null; playback?.end()
        return true
    }
    /** Stop on the held channel's panel. */
    fun stopHeld() { detailId.value = null; playback?.end() }
    /** The hand-over to Live TV was carried out. */
    fun completeHandoff() { detailId.value = null; playback?.consumeHandoff() }

    // ---- follows and reminders (each is the person choosing; none starts anything)

    private fun openEvent(): SportsEvent? = detailId.value?.let(::findEvent)
    /** An event of the hub window, or one a page loaded for its Catch-Up. */
    private fun findEvent(id: String): SportsEvent? = loaded.value.events.firstOrNull { it.id == id } ?: history.value.events.firstOrNull { it.id == id }

    fun follow(kind: app.streamsetu.tv.sports.personal.FollowKind, name: String) {
        val e = openEvent() ?: return; val f = follows ?: return
        work.launch { personalNote.value = if (f.follow(e, kind, name, loaded.value.identities) == app.streamsetu.tv.sports.personal.FollowResult.Refused) "That is no longer available." else null }
    }
    fun unfollow(f: app.streamsetu.tv.sports.personal.Follow) { work.launch { follows?.unfollow(f) } }
    fun clearFollows() { work.launch { follows?.clear() } }
    fun openManage() { managing.value = true }
    fun closeManage() { managing.value = false }

    fun remind(leadMs: Long) {
        val e = openEvent() ?: return; val r = reminders ?: return
        work.launch {
            personalNote.value = when (val res = r.create(e, leadMs, loaded.value.events)) {
                is app.streamsetu.tv.sports.personal.CreateResult.Created -> if (res.permission == app.streamsetu.tv.sports.personal.NotificationState.DENIED) "System notifications are off. You will still see this reminder while StreamSetu is open." else null
                is app.streamsetu.tv.sports.personal.CreateResult.Exists -> "A reminder is already set for this event."
                app.streamsetu.tv.sports.personal.CreateResult.Refused -> "That is no longer available."
            }
        }
    }
    fun changeReminder(id: String, leadMs: Long) { work.launch { reminders?.change(id, leadMs) } }
    fun removeReminder(id: String) { work.launch { reminders?.remove(id) } }
    fun keepReminder(id: String) { work.launch { reminders?.keep(id) } }

    /** A reminder was opened (from a notification or the banner): once the events are loaded and it is matched, its event detail opens; otherwise the schedule is shown as it is. */
    fun openReminder(id: String) {
        val r = reminders ?: return
        work.launch {
            loaded.first { !it.loading }
            r.reassociate(loaded.value.events)                                          // the reminder is matched against exactly what was loaded, not against an earlier pass
            val row = r.get(id) ?: return@launch                                        // another profile's reminder opens nothing
            row.matchedEventId?.let { e -> if (loaded.value.events.any { it.id == e }) { mySports.value = false; detailId.value = e } }
        }
    }

    // ---- team and competition pages, and links from Search (each is the person choosing; none starts a stream or asks a provider)

    /** Opens the page of a team or competition. Opening an event first closes any playback that came from the event being left. */
    fun openPage(ref: app.streamsetu.tv.sports.discovery.PageRef) {
        linkNotice.value = null
        if (detailId.value != null) { playback?.end(); detailId.value = null; panel.value = null; abilities.value = null }
        if (pages.value.isEmpty() || pagesEpoch != epoch.value) pages.value = emptyList()
        pagesEpoch = epoch.value
        pages.update { stack -> val at = stack.indexOf(ref); if (at >= 0) stack.take(at + 1) else (stack + ref).takeLast(MAX_PAGES) }
        refreshHistory()
    }

    /** Back from a page. False when none was open. */
    fun closePage(): Boolean { if (pages.value.isEmpty()) return false; pages.update { it.dropLast(1) }; refreshHistory(); return true }

    /** Open Guide on the open event's programme. The channel is checked again first; if no feed may be reached nothing opens and the person is told. */
    fun openGuide(open: (app.streamsetu.tv.sports.discovery.GuideTarget) -> Unit) {
        val e = openEvent() ?: return; val order = playback?.recommendedFor(e.id)?.first?.map { it.feed.channelId }.orEmpty(); val myEpoch = epoch.value
        work.launch {
            val t = deps.guideTarget(e, order)
            if (myEpoch != epoch.value) return@launch
            if (t == null) personalNote.value = "That channel is not available any more." else kotlinx.coroutines.withContext(Dispatchers.Main) { open(t) }
        }
    }

    fun clearOrigin() { fromSearch.value = false }
    fun hubFromSearch() = fromSearch.value
    fun pageCount() = pages.value.size

    fun followPage(ref: app.streamsetu.tv.sports.discovery.PageRef) {
        val f = follows ?: return
        work.launch {
            val e = app.streamsetu.tv.sports.discovery.SportsPages.eventsFor(ref, loaded.value.events, loaded.value.identities).firstOrNull() ?: run { personalNote.value = "That is no longer available."; return@launch }
            val kind = if (ref.kind == app.streamsetu.tv.sports.discovery.PageKind.TEAM) app.streamsetu.tv.sports.personal.FollowKind.PARTICIPANT else app.streamsetu.tv.sports.personal.FollowKind.COMPETITION
            f.follow(e, kind, ref.name, loaded.value.identities)
        }
    }

    fun unfollowPage(ref: app.streamsetu.tv.sports.discovery.PageRef) {
        val kind = if (ref.kind == app.streamsetu.tv.sports.discovery.PageKind.TEAM) app.streamsetu.tv.sports.personal.FollowKind.PARTICIPANT else app.streamsetu.tv.sports.personal.FollowKind.COMPETITION
        unfollow(app.streamsetu.tv.sports.personal.Follow(kind, ref.sport, ref.key, ref.name))
    }

    /** The person chose which team or competition an old follow means. */
    fun chooseFollow(f: app.streamsetu.tv.sports.personal.Follow, key: String) { val s = follows ?: return; work.launch { s.choose(f, key, loaded.value.identities) } }

    /** A Sports result chosen in Search. Once the events are loaded: an event opens its detail, a team or competition its page. What is not there any more says so. */
    fun openLink(t: app.streamsetu.core.data.repo.SearchTarget.OpenSports) {
        fromSearch.value = true
        work.launch {
            loaded.first { !it.loading }
            val sport = Sport.values().firstOrNull { it.name == t.sport }
            when (t.kind) {
                "event", "recording" -> {
                    val id = t.eventId
                    if (id != null && loaded.value.events.any { it.id == id }) { mySports.value = false; selected.value = null; openDetail(id) } else { linkNotice.value = "That is not available any more."; fromSearch.value = false }
                }
                "team", "competition" -> if (sport != null) {
                    mySports.value = false
                    openPage(app.streamsetu.tv.sports.discovery.PageRef(if (t.kind == "team") app.streamsetu.tv.sports.discovery.PageKind.TEAM else app.streamsetu.tv.sports.discovery.PageKind.COMPETITION, sport, t.key, t.name))
                } else { linkNotice.value = "That is not available any more."; fromSearch.value = false }
                else -> { linkNotice.value = "That is not available any more."; fromSearch.value = false }
            }
        }
    }

    /**
     * Catch-Up for the open page, or for My Sports: loaded only when one of those is showing, back as far as the channels declare (three days at most), kept apart from the hub's own events, cached
     * for two windows at most, and dropped when the page closes or who may see what changes. What the page already shows stays on screen while it loads.
     */
    private fun refreshHistory() {
        historyJob?.cancel()
        val scope = currentScope; val ref = pages.value.lastOrNull(); val my = mySports.value; val myEpoch = epoch.value
        if (scope == null || (ref == null && !my)) { history.value = Hist.NONE; return }
        historyJob = work.launch {
            val started = System.nanoTime()
            try {
              try {
                val now = deps.now()
                val ids = loaded.value.events.filter { ref == null || it.sport == ref.sport }.flatMap { e -> e.feeds.filter { it.catchUp }.map { it.channelId } }.distinct().take(400)
                val days = minOf(deps.catchUpDays(ids), app.streamsetu.tv.sports.discovery.SportsWindow.MAX_CATCH_UP_DAYS)
                if (days <= 0) { history.value = Hist("none", emptyList(), false); return@launch }
                val (from, to) = app.streamsetu.tv.sports.discovery.SportsWindow.history(now, days)
                val key = "${scope.hashCode()}|$days|$to"
                historyCache[key]?.let { history.value = Hist(key, it, false, myEpoch); return@launch }
                history.update { it.copy(loading = true) }
                val r = kotlinx.coroutines.withContext(Dispatchers.Default) { deps.history(scope, from, to) }
                if (currentScope != scope || myEpoch != epoch.value) return@launch                        // who may see what changed meanwhile: nothing from this run is shown
                historyCache[key] = r.events; while (historyCache.size > 2) historyCache.remove(historyCache.keys.first())
                history.value = Hist(key, r.events, false, myEpoch)
                discovery.record(app.streamsetu.tv.sports.discovery.DiscoveryReport(app.streamsetu.tv.sports.discovery.DiscoveryKind.CATCH_UP, if (r.events.isEmpty()) app.streamsetu.tv.sports.discovery.DiscoveryOutcome.EMPTY else app.streamsetu.tv.sports.discovery.DiscoveryOutcome.OK, r.events.size, (System.nanoTime() - started) / 1_000_000L, r.cacheHit))
              } finally { if (kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]?.isCancelled != true) historySettled.incrementAndGet() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                history.update { it.copy(loading = false) }
                discovery.record(app.streamsetu.tv.sports.discovery.DiscoveryReport(app.streamsetu.tv.sports.discovery.DiscoveryKind.CATCH_UP, app.streamsetu.tv.sports.discovery.DiscoveryOutcome.ERROR, 0, (System.nanoTime() - started) / 1_000_000L, false, failure = e.javaClass.simpleName))
            }
        }
    }

    // ---- recording, start over and catch-up (each is the person choosing; none runs from focus)

    private var abilitiesGen = 0

    /** Works out, from what the app already knows (no provider is asked), what the open event can offer. A result that arrives after the person has moved on is dropped. */
    private fun refreshAbilities(eventId: String) {
        val svc = recordings ?: return; val gen = ++abilitiesGen
        work.launch {
            val e = findEvent(eventId) ?: run { if (gen == abilitiesGen) abilities.value = null; return@launch }
            val (p, archive) = kotlinx.coroutines.withContext(Dispatchers.Default) { svc.plan(e, null, PRE_DEFAULT_MS, POST_DEFAULT_MS, loaded.value.events) to svc.archiveOptions(e, deps.now()) }   // not on the main thread
            val (startOver, catchUp) = archive
            if (gen != abilitiesGen || detailId.value != eventId) return@launch
            val any = p.feeds.any { it.recordable }
            abilities.value = EventAbilities(eventId, canRecord = any && app.streamsetu.tv.sports.recording.PlanIssue.EVENT_OVER !in p.issues,
                recordHint = if (!any && p.feeds.isNotEmpty() && app.streamsetu.tv.sports.recording.PlanIssue.EVENT_OVER !in p.issues) "Recording isn't supported for this stream format yet." else null, startOver = startOver, catchUp = catchUp)
        }
    }

    fun openRecord() { val e = openEvent() ?: return; buildPanel(e.id, null, (PRE_DEFAULT_MS / 60_000).toInt(), (POST_DEFAULT_MS / 60_000).toInt()) }
    fun closeRecord() { panel.value = null }
    fun recordPadding(preMin: Int, postMin: Int) { val p = panel.value ?: return; buildPanel(p.eventId, p.chosen, preMin, postMin) }
    fun recordFeed(channelId: String) { val p = panel.value ?: return; buildPanel(p.eventId, channelId, p.preMin, p.postMin) }

    private fun buildPanel(eventId: String, chosen: String?, preMin: Int, postMin: Int) {
        val svc = recordings ?: return
        work.launch {
            val e = findEvent(eventId) ?: return@launch
            val p = kotlinx.coroutines.withContext(Dispatchers.Default) { svc.plan(e, chosen, preMin * 60_000L, postMin * 60_000L, loaded.value.events) }
            if (detailId.value != eventId) return@launch
            val names = loaded.value.sourceNames
            val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).also { it.timeZone = deps.zone }
            val gb = { b: Long -> String.format(java.util.Locale.US, "%.1f", b / 1_073_741_824.0) }
            panel.value = RecordPanelUi(
                eventId, p.recordNow, if (p.recordNow) "Starting now, until " + clock.format(java.util.Date(e.endMs)) else clock.format(java.util.Date(e.startMs)) + " – " + clock.format(java.util.Date(e.endMs)),
                p.feeds.map { f -> e.feeds.firstOrNull { it.channelId == f.channelId }?.let { RecordFeedUi(f.channelId, it.channelName + "  ·  " + (names[it.sourceId] ?: "Playlist"), f.recordable) } }.filterNotNull(),
                p.chosenChannelId, preMin, postMin, durationText(p.durationMs),
                p.estimate?.let { "About ${gb(it.lowBytes)} to ${gb(it.highBytes)} GB (an estimate)" }, if (p.freeBytes > 0) "${gb(p.freeBytes)} GB free" else null,
                p.issues.map(::problemText), p.notes.map(::noteText), p.canConfirm,
            )
        }
    }

    private fun durationText(ms: Long): String { val m = (ms / 60_000L).coerceAtLeast(0); return if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min" }

    private fun problemText(i: app.streamsetu.tv.sports.recording.PlanIssue) = when (i) {
        app.streamsetu.tv.sports.recording.PlanIssue.EVENT_OVER -> "This event is over."
        app.streamsetu.tv.sports.recording.PlanIssue.NO_RECORDABLE_FEED -> "Recording isn't supported for this stream format yet."
        app.streamsetu.tv.sports.recording.PlanIssue.DUPLICATE_EXACT -> "This event is already scheduled."
        app.streamsetu.tv.sports.recording.PlanIssue.SAME_EVENT_SCHEDULED -> "This event is already scheduled with other settings."
        app.streamsetu.tv.sports.recording.PlanIssue.CONNECTION_LIMIT -> "Your provider has no free connection for a recording at that time."
        app.streamsetu.tv.sports.recording.PlanIssue.DEVICE_RECORDING_LIMIT -> "Two recordings would run at once, which is as many as this device records."
        app.streamsetu.tv.sports.recording.PlanIssue.STORAGE_NOT_ENOUGH -> "There is not enough free space to record this."
        app.streamsetu.tv.sports.recording.PlanIssue.STORAGE_UNAVAILABLE -> "The recordings folder cannot be written to."
        app.streamsetu.tv.sports.recording.PlanIssue.REVIEW_REQUIRED -> "The schedule changed and needs a review."
    }

    private fun noteText(n: app.streamsetu.tv.sports.recording.PlanNote) = when (n) {
        app.streamsetu.tv.sports.recording.PlanNote.OVERLAP_ALLOWED -> "It overlaps another recording that can run alongside it."
        app.streamsetu.tv.sports.recording.PlanNote.STORAGE_UNCERTAIN -> "Free space may not be enough: the size is only an estimate."
        app.streamsetu.tv.sports.recording.PlanNote.FORMAT_UNCONFIRMED -> "The stream's format is confirmed when recording starts."
    }

    /** Confirms what the panel shows; everything is checked again first. Nothing else is cancelled or replaced. */
    fun confirmRecord() {
        val svc = recordings ?: return; val p = panel.value ?: return
        work.launch {
            val e = findEvent(p.eventId) ?: return@launch
            when (val out = svc.record(e, p.chosen, p.preMin * 60_000L, p.postMin * 60_000L, loaded.value.events)) {
                is app.streamsetu.tv.sports.recording.RecordOutcome.Scheduled -> { panel.value = null; personalNote.value = if (p.recordNow) "Recording started." else "Recording scheduled. It is listed in Settings, under Recordings." }
                is app.streamsetu.tv.sports.recording.RecordOutcome.Exists -> { panel.value = null; personalNote.value = "This event is already scheduled." }
                is app.streamsetu.tv.sports.recording.RecordOutcome.Blocked -> buildPanel(p.eventId, p.chosen, p.preMin, p.postMin)
            }
            refreshAbilities(p.eventId)
        }
    }

    fun cancelRecording(id: String) { val svc = recordings ?: return; work.launch { svc.cancel(id); detailId.value?.let(::refreshAbilities) } }
    fun stopRecording(id: String) { val svc = recordings ?: return; work.launch { svc.stop(id); svc.syncFromExecutor(); detailId.value?.let(::refreshAbilities) } }

    /** Start Over / Catch-Up on one feed. The channel and the offer are checked again now, the playback is the app's catch-up playback, and there is never a fall back to live. */
    fun archive(channelId: String, startOver: Boolean, opened: () -> Unit) {
        val e = openEvent() ?: return; val svc = recordings ?: return
        work.launch {
            val ok = svc.playArchive(e, channelId, startOver) { }
            if (ok) { playback?.end(stopPlayback = false); kotlinx.coroutines.withContext(Dispatchers.Main) { opened() } } else personalNote.value = "That is not available any more."
        }
    }

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
        if (!first) epoch.value = epoch.value + 1                                        // one synchronous write: from the next state nothing made under the old context is drawn or can be acted on
        if (!first) { reminders?.securityChanged(); panel.value = null; abilities.value = null; playback?.invalidate(); historyJob?.cancel(); historyCache.clear() }             // the banner goes at once; a pending play request or open feed list from before the change is dropped
        startLoad(clear = !first)                          // a change to who may see what: clear at once (the first value has nothing to clear)
        if (!first) { history.value = Hist.NONE; pages.value = emptyList(); fromSearch.value = false; linkNotice.value = null }       // after the events are cleared, so no frame shows an old page over new content
    }

    private fun startLoad(clear: Boolean) {
        val scope = currentScope ?: return
        loadJob?.cancel()
        val gen = ++generation
        val myEpoch = epoch.value
        if (clear) { loaded.value = Loaded(loading = true, epoch = myEpoch); detailId.value = null; playback?.revalidate() }          // the stream goes on only if its channel is still allowed (see SportsPlaybackCoordinator.revalidate)
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
                val identities = kotlinx.coroutines.withContext(Dispatchers.Default) { app.streamsetu.tv.sports.discovery.IdentityIndex.build(r.events) }
                if (gen != generation || myEpoch != epoch.value) return@launch
                loadedAt = deps.now()
                loaded.value = Loaded(events = r.events, revision = r.revision, sourceNames = names, hasGuide = hasGuide, loading = false, identities = identities, epoch = myEpoch)
                discovery.record(app.streamsetu.tv.sports.discovery.DiscoveryReport(app.streamsetu.tv.sports.discovery.DiscoveryKind.IDENTITIES, app.streamsetu.tv.sports.discovery.DiscoveryOutcome.OK, identities.identityCount, ms(), r.cacheHit, identities.ambiguousCount, r.events.count { it.participants.isEmpty() && it.competition == null }))
                follows?.resolveLegacy(identities)                                                // an old follow that fits exactly one identity becomes it; the others stay as they are
                diagnostics.record(SportsLoadReport.of(r.events, now, deps.zone, scope.sourceIds.size, ms(), r.cacheHit))
                reminders?.reassociate(r.events)                                                  // durable reminders find their events again, in one batch
                recordings?.let { kotlinx.coroutines.withContext(Dispatchers.Default) { it.reassociate(r.events) } }                                                 // so do recordings that have not started, on the same evidence
                detailId.value?.let(::refreshAbilities)
                refreshHistory()                                                                  // a page's Catch-Up follows the guide, behind what is already shown
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

    private fun recordingUi(r: app.streamsetu.core.data.db.SportsRecordingEntity): RecordingUi {
        val status = app.streamsetu.tv.sports.recording.SportsRecordingStatus.valueOf(r.status)
        val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).also { it.timeZone = deps.zone }
        val file = recordings?.fileOf(r.scheduleId)
        val line = when (status) {
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.SCHEDULED -> "Recording scheduled · " + clock.format(java.util.Date(r.startMs))
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.RECORDING -> "Recording now"
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.COMPLETED -> "Recorded"
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.FAILED -> "Recording failed" + (r.failure?.let { " · " + failureText(it) } ?: "") + if (file != null) ". The part recorded was kept." else ""
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.REVIEW_REQUIRED -> "Schedule changed — review required"
            app.streamsetu.tv.sports.recording.SportsRecordingStatus.CANCELLED -> ""
        }
        return RecordingUi(r.id, status, line, status == app.streamsetu.tv.sports.recording.SportsRecordingStatus.SCHEDULED || status == app.streamsetu.tv.sports.recording.SportsRecordingStatus.REVIEW_REQUIRED,
            status == app.streamsetu.tv.sports.recording.SportsRecordingStatus.RECORDING, file?.let { app.streamsetu.core.data.repo.RecordingFiles.playId(it) }, status == app.streamsetu.tv.sports.recording.SportsRecordingStatus.REVIEW_REQUIRED)
    }

    private fun failureText(f: String) = when (f) {
        "CONNECTION_LIMIT" -> "no free connection from the provider"; "DEVICE_RECORDING_LIMIT" -> "two recordings were already running"; "STORAGE" -> "not enough free space"
        "UNSUPPORTED_FORMAT" -> "the stream format cannot be recorded yet"; "ENDED_EARLY" -> "the stream stopped early"; "INTERRUPTED" -> "it was interrupted"; "MISSED" -> "the device was off"
        "UNAUTHORIZED", "PROFILE_CHANGED", "CHANNEL_MISSING", "SOURCE_OFF" -> "it was no longer allowed"; "REVIEW_REQUIRED" -> "the schedule needed a review"; else -> "it did not finish"
    }

    private fun build(l0: Loaded, sel0: Sport?, detail0: String?, now: Long, x: Extras): SportsHubUiState {
        if (android.os.Looper.getMainLooper() === android.os.Looper.myLooper()) buildsOnMain.incrementAndGet()
        val stale = l0.epoch != x.nav.epoch                                                    // made under an earlier context: not drawn
        val l = if (stale) Loaded(loading = true, epoch = x.nav.epoch) else l0
        val sel = sel0; val detail = if (stale) null else detail0
        val navPages = if (stale || x.nav.pagesEpoch != x.nav.epoch) emptyList() else x.nav.pages
        val pb = x.playback; val ps = x.personal
        val play = if (detail != null && playback != null) {
            val (ranked, why) = playback.recommendedFor(detail)
            SportsDetailPlay(ranked.map { it.feed.channelId }, ranked.filter { it.deprioritized }.map { it.feed.channelId }.toSet(), why, pb)
        } else SportsDetailPlay()
        val reminded = ps.reminders.filter { it.status == app.streamsetu.tv.sports.personal.ReminderStatus.SCHEDULED.name }.mapNotNull { it.matchedEventId }.toSet()
        val idx = l.identities; val hist = if (l.loading || x.nav.history.epoch != x.nav.epoch) Hist.NONE else x.nav.history          // Catch-Up of an earlier scope is never drawn while the events are being rebuilt
        val followSet = ps.follows.withIndex(idx)
        val recIdx = app.streamsetu.tv.sports.discovery.RecordingIndex(x.recs.rows)
        val personal = app.streamsetu.tv.sports.personal.Personalization(followSet, reminded, ps.my)
        val remindedKeys = ps.reminders.filter { it.status == app.streamsetu.tv.sports.personal.ReminderStatus.SCHEDULED.name }.map { it.identity + "#" + it.slot }.toSet()
        val clock = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).also { it.timeZone = deps.zone }
        fun reminderUi(r: app.streamsetu.core.data.db.SportsReminderEntity) = ReminderUi(
            r.id, r.leadMs, app.streamsetu.tv.sports.personal.ReminderLeads.setText(r.leadMs), clock.format(java.util.Date(r.startMs)),
            app.streamsetu.tv.sports.personal.ReminderStatus.valueOf(r.status), r.status == app.streamsetu.tv.sports.personal.ReminderStatus.UNMATCHED.name && !r.kept,
        )
        val shownEvents = if (detail != null && l.events.none { it.id == detail }) l.events + hist.events else l.events          // a Catch-Up event a page listed
        val r = SportsSections.build(shownEvents, now, deps.zone, sel, detail, l.sourceNames, play = play, personal = personal,
            followOptions = { e -> if (follows == null) emptyList() else app.streamsetu.tv.sports.personal.eventOptions(e, idx).map { o ->
                val on = followSet.isFollowing(o.kind, e.sport, o.key)
                FollowOptionUi(o.kind, e.sport, o.name, (if (on) "Following " else "Follow ") + o.name, on, o.key)
            } },
            pageLinks = { e -> app.streamsetu.tv.sports.personal.eventOptions(e, idx).filter { it.kind != app.streamsetu.tv.sports.personal.FollowKind.SPORT }.map { o ->
                val team = o.kind == app.streamsetu.tv.sports.personal.FollowKind.PARTICIPANT
                PageLinkUi((if (team) "Team page · " else "Competition page · ") + o.name, app.streamsetu.tv.sports.discovery.PageRef(if (team) app.streamsetu.tv.sports.discovery.PageKind.TEAM else app.streamsetu.tv.sports.discovery.PageKind.COMPETITION, e.sport, o.key, o.name))
            } },
            recordingFor = { e -> recIdx.forEvent(e)?.let(::recordingUi) }, abilities = x.recs.abilities,
            reminderFor = { e ->
                val identity = app.streamsetu.tv.sports.personal.SportsKeys.identity(e); val slot = app.streamsetu.tv.sports.personal.SportsKeys.slot(e.startMs)
                ps.reminders.firstOrNull { it.matchedEventId == e.id || (it.identity == identity && it.slot == slot) }?.let(::reminderUi)
            })
        val pageRef = navPages.lastOrNull()
        val needEnv = pageRef != null || (r.my && !l.loading)
        val env = if (!needEnv) null else app.streamsetu.tv.sports.discovery.SportsPages.Env(
            l.events, hist.events, now, deps.zone, idx, followSet, recIdx, remindedKeys,
            decorate = { e, c -> c.copy(reminded = e.id in reminded || app.streamsetu.tv.sports.discovery.SportsPages.eventKey(e) in remindedKeys, recordingLabel = recIdx.forEvent(e)?.let { rr -> SportsSections.recordingMark(recordingUi(rr)) }) },
            playIdOf = { rr -> recordings?.fileOf(rr.scheduleId)?.let { app.streamsetu.core.data.repo.RecordingFiles.playId(it) } },
            clock = { ms -> clock.format(java.util.Date(ms)) }, labels = SportsSections.Labels(deps.zone, java.util.Locale.getDefault(), now))
        val page = if (pageRef != null && env != null) { discoveryBuilds.incrementAndGet(); app.streamsetu.tv.sports.discovery.SportsPages.page(pageRef, env, hist.loading) } else null
        val board = if (r.my && env != null) { discoveryBuilds.incrementAndGet(); app.streamsetu.tv.sports.discovery.SportsPages.board(env) } else null
        val message = when {
            l.loading -> null
            board != null && board.isEmpty -> SportsHubMessage.NoFollowed
            board == null && r.my && r.live.isEmpty() && r.soon.isEmpty() && r.today.isEmpty() && r.upcoming.isEmpty() -> SportsHubMessage.NoFollowed
            r.live.isEmpty() && r.soon.isEmpty() && r.today.isEmpty() && r.upcoming.isEmpty() && l.error != null -> SportsHubMessage.Error(l.error)
            l.events.none { it.endMs > now } && !l.hasGuide -> SportsHubMessage.NoGuide
            l.events.none { it.endMs > now } -> SportsHubMessage.NoSports
            else -> null
        }
        val manage = if (!ps.manage) null else ManageUi(
            followSet.follows.filter { it.kind == app.streamsetu.tv.sports.personal.FollowKind.SPORT }.sortedBy { it.displayName },
            followSet.follows.filter { it.kind == app.streamsetu.tv.sports.personal.FollowKind.COMPETITION }.sortedBy { it.displayName },
            followSet.follows.filter { it.kind == app.streamsetu.tv.sports.personal.FollowKind.PARTICIPANT }.sortedBy { it.displayName },
            ps.reminders.filter { it.status != app.streamsetu.tv.sports.personal.ReminderStatus.ENDED.name }.map(::reminderUi), ps.note,
            choices = followSet.follows.filter { followSet.status(it) == app.streamsetu.tv.sports.discovery.FollowStatus.UNRESOLVED }.associate { f ->
                ManageUi.manageId(f) to followSet.candidates(f).map { k -> ChoiceUi(k, (idx.displayName(k) ?: f.displayName) + (if (app.streamsetu.tv.sports.discovery.SportsIdentity.isScoped(k)) "  ·  " + (l.sourceNames[k.substringAfter('@')] ?: "another playlist") else "")) } },
            unavailable = followSet.follows.filter { followSet.status(it) == app.streamsetu.tv.sports.discovery.FollowStatus.UNAVAILABLE }.map { ManageUi.manageId(it) }.toSet(),
        )
        return SportsHubUiState(l.loading, l.refreshing, r.selected, r.filters, r.live, r.soon, r.today, r.upcoming,
            r.detail?.copy(multiviewNote = x.note) ?: pb.held?.takeIf { !pb.handoff }?.let { SportsSections.heldDetail(it.channelName) }, message, l.revision, now, pb.handoff, x.multiviewCount, r.my, !ps.follows.isEmpty, manage)
            .let { it.copy(recordPanel = x.recs.panel, page = page, board = board, fromSearch = x.nav.fromSearch, linkNotice = x.nav.notice, pageDepth = navPages.size) }
            .let { if (it.detail != null && ps.note != null) it.copy(detail = it.detail.copy(multiviewNote = it.detail.multiviewNote ?: ps.note)) else it }
    }
}

private const val MAX_PAGES = 8
private const val PRE_DEFAULT_MS = 60_000L
private const val POST_DEFAULT_MS = 5 * 60_000L
