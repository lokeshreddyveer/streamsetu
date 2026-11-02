package app.streamsetu.tv.ui.screens.sports

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SportsBaseball
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsCricket
import androidx.compose.material.icons.filled.SportsFootball
import androidx.compose.material.icons.filled.SportsGolf
import androidx.compose.material.icons.filled.SportsHockey
import androidx.compose.material.icons.filled.SportsMma
import androidx.compose.material.icons.filled.SportsMotorsports
import androidx.compose.material.icons.filled.SportsRugby
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Add
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.sports.Sport
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.ChannelLogo
import app.streamsetu.tv.ui.components.FocusMemory
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.LocalContentEntry
import app.streamsetu.tv.ui.components.LocalFocusEnabled
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.components.requestFocusOnFrames
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.ui.theme.ui

/** What the screen can do. Each is a function the owner supplies; the screen itself never reaches a repository. */
class SportsActions(
    val select: (Sport?) -> Unit,
    val open: (String) -> Unit,
    val closeDetail: () -> Unit,
    val refresh: () -> Unit,
    val refreshGuide: () -> Unit,
    val openGuideSettings: () -> Unit,
    val viewSportsChannels: () -> Unit,
    /** The remote is on this event (its id and its position among all cards): remembered so coming back finds it. */
    val remember: (id: String, index: Int) -> Unit,
    /** Watch Best Feed, and OK on one feed. Each is the person pressing OK; nothing plays from focus. */
    val watchBest: () -> Unit = {},
    val watchFeed: (channelId: String) -> Unit = {},
    val retryPlayback: () -> Unit = {},
    /** Stops the Sports playback and leaves the event detail open. */
    val backToEvent: () -> Unit = {},
    /** The embedded picture's place in the window (null when it is gone), and OK on it (the existing fullscreen player). */
    val previewBounds: (androidx.compose.ui.geometry.Rect?) -> Unit = {},
    val openFullscreen: () -> Unit = {},
    val previewFocused: (Boolean) -> Unit = {},
    /** Stop on the panel of a channel that outlived its event. */
    val stopHeld: () -> Unit = {},
    /** Add to Multiview: the open event's recommended feed, or one chosen feed. The list only grows; nothing plays. */
    val addToMultiview: () -> Unit = {},
    val addFeedToMultiview: (channelId: String) -> Unit = {},
    /** Open the Multiview builder (the Sports stream is released first). */
    val openMultiview: () -> Unit = {},
    /** My Sports, following and reminders. Each is the person choosing; none starts anything. */
    val selectMy: () -> Unit = {},
    val follow: (kind: app.streamsetu.tv.sports.personal.FollowKind, name: String) -> Unit = { _, _ -> },
    val unfollow: (app.streamsetu.tv.sports.personal.Follow) -> Unit = {},
    val clearFollows: () -> Unit = {},
    val openManage: () -> Unit = {},
    val closeManage: () -> Unit = {},
    val remind: (leadMs: Long) -> Unit = {},
    val changeReminder: (id: String, leadMs: Long) -> Unit = { _, _ -> },
    val removeReminder: (id: String) -> Unit = {},
    val keepReminder: (id: String) -> Unit = {},
    /** Recording, start over and catch-up. Each is the person pressing OK on the action; the same checks are made again when it runs. */
    val openRecord: () -> Unit = {},
    val closeRecord: () -> Unit = {},
    val recordPadding: (preMin: Int, postMin: Int) -> Unit = { _, _ -> },
    val recordFeed: (channelId: String) -> Unit = {},
    val confirmRecord: () -> Unit = {},
    val cancelRecording: (id: String) -> Unit = {},
    val stopRecording: (id: String) -> Unit = {},
    val watchRecording: (playId: String) -> Unit = {},
    val startOver: (channelId: String) -> Unit = {},
    val watchCatchUp: (channelId: String) -> Unit = {},
    /** Team and competition pages, and what an unresolved follow means. Each is the person pressing OK. */
    val openPage: (app.streamsetu.tv.sports.discovery.PageRef) -> Unit = {},
    val followPage: (app.streamsetu.tv.sports.discovery.PageRef) -> Unit = {},
    val unfollowPage: (app.streamsetu.tv.sports.discovery.PageRef) -> Unit = {},
    val chooseFollow: (app.streamsetu.tv.sports.personal.Follow, String) -> Unit = { _, _ -> },
    val openGuide: () -> Unit = {},
    val closePageUi: () -> Unit = {},
)

/** The page as the shell shows it. Refresh Guide uses the application's own guide refresh. */
@Composable
fun SportsScreen(vm: SportsViewModel, c: AppContainer, nav: Navigator) = SportsScreenHost(vm, nav, playRecording = { playId -> app.streamsetu.tv.play(c, nav, app.streamsetu.core.model.MoviePlayable(app.streamsetu.core.model.Movie(playId, "recordings", null, "Recording", null, null, null, null, "", 0))) }) { c.ensureGuide(force = true) }

/** Wires the screen to the ViewModel, the Navigator (tab, Back, focus memory) and the application's existing routes. It does no work of its own. */
@Composable
fun SportsScreenHost(vm: SportsViewModel, nav: Navigator, playRecording: (String) -> Unit = {}, refreshGuideNow: () -> Unit) {
    val state by vm.uiState.collectAsStateWithLifecycle()
    val current by rememberUpdatedState(state)
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    LaunchedEffect(Unit) { vm.onEntered() }
    LaunchedEffect(nav.pendingSportsReminder) { nav.pendingSportsReminder?.let { vm.openReminder(it); nav.pendingSportsReminder = null } }
    LaunchedEffect(nav.pendingSportsTarget) { nav.pendingSportsTarget?.let { vm.openLink(it); nav.pendingSportsTarget = null } }

    // Back closes the detail first; with none open the page does not take Back, so the sidebar opens.
    var previewFocused by remember { mutableStateOf(false) }
    var returnTick by remember { mutableStateOf(0) }
    // Back: from the embedded picture the remote goes back to the feed list (playback goes on); from the detail it closes the event, which ends what played from it.
    DisposableEffect(vm) {
        val hook: () -> Boolean = {
            if (current.recordPanel != null) { vm.closeRecord(); true }
            else if (current.manage != null) { vm.closeManage(); true }
            else if (current.detail != null) {
                if (previewFocused) returnTick++
                else if (vm.closeDetail() && current.fromSearch && current.page == null) { vm.clearOrigin(); nav.returnToSearch() }          // an event opened from Search goes back to its result
                true
            }
            else if (current.page != null) { vm.closePage(); if (current.fromSearch && current.pageDepth <= 1) { vm.clearOrigin(); nav.returnToSearch() }; true }
            else false
        }
        nav.backHook = hook
        onDispose { if (nav.backHook === hook) nav.backHook = null }
    }

    val ids = remember(state.live, state.startingSoon, state.today, state.upcoming, state.board) { state.cardIds }
    // The event to put the remote back on: the one it was on if it is still listed, else the nearest position, else the first control.
    val restoreId = nav.memory.target(Tab.SPORTS, ids)?.let { ids.getOrNull(it) }
    var origin by remember { mutableStateOf<String?>(null) }

    val actions = remember(vm, nav) {
        SportsActions(
            select = vm::select,
            open = { id -> origin = id; vm.openDetail(id) },
            closeDetail = vm::closeDetail,
            refresh = vm::refresh,
            refreshGuide = { refreshGuideNow(); vm.refresh() },
            openGuideSettings = { nav.pendingSettings = app.streamsetu.tv.ui.screens.settings.GuideSettingsPage.request; nav.go(Tab.SETTINGS) },
            viewSportsChannels = { nav.go(Tab.LIVE) },
            remember = { id, index -> nav.memory.remember(Tab.SPORTS, id, index) },
            watchBest = vm::watchBest, watchFeed = vm::watchFeed, retryPlayback = vm::retryPlayback, backToEvent = vm::stopPlayback,
            previewBounds = { nav.videoBounds = it },
            openFullscreen = { nav.liveFullscreen = true; nav.open(app.streamsetu.tv.nav.Overlay.Player) },
            previewFocused = { previewFocused = it }, stopHeld = vm::stopHeld,
            addToMultiview = { vm.addToMultiview() }, addFeedToMultiview = { vm.addToMultiview(it) },
            selectMy = vm::selectMy, follow = vm::follow, unfollow = vm::unfollow, clearFollows = vm::clearFollows, openManage = vm::openManage, closeManage = vm::closeManage,
            remind = vm::remind, changeReminder = vm::changeReminder, removeReminder = vm::removeReminder, keepReminder = vm::keepReminder,
            openRecord = vm::openRecord, closeRecord = vm::closeRecord, recordPadding = vm::recordPadding, recordFeed = vm::recordFeed, confirmRecord = vm::confirmRecord,
            cancelRecording = vm::cancelRecording, stopRecording = vm::stopRecording,
            watchRecording = { playId -> vm.stopPlayback(); playRecording(playId) },
            startOver = { id -> vm.archive(id, true) { nav.liveFullscreen = false; nav.open(app.streamsetu.tv.nav.Overlay.Player) } },
            watchCatchUp = { id -> vm.archive(id, false) { nav.liveFullscreen = false; nav.open(app.streamsetu.tv.nav.Overlay.Player) } },
            openMultiview = { vm.beforeMultiview(); nav.open(app.streamsetu.tv.nav.Overlay.SportsMultiview) },
            openPage = vm::openPage, followPage = vm::followPage, unfollowPage = vm::unfollowPage, chooseFollow = vm::chooseFollow,
            openGuide = { vm.openGuide { t -> nav.openGuideAt(t) } },
            closePageUi = { vm.closePage(); if (vm.hubFromSearch() && vm.pageCount() == 0) { vm.clearOrigin(); nav.returnToSearch() } },
        )
    }
    // Sports can no longer keep the embedded player for a stream that is still allowed: it goes to Live TV's embedded channel player, selected there as the channel now playing. Nothing is
    // restarted and fullscreen is never opened: that stays the person's own action. The Sports panel is told first so leaving it does not stop the stream.
    LaunchedEffect(state.playbackHandoff) {
        if (!state.playbackHandoff) return@LaunchedEffect
        vm.completeHandoff(); nav.sportsReturnToCard = true; nav.go(Tab.LIVE)
    }
    // Leaving Sports releases the stream (a provider may allow only one connection), unless the fullscreen player has taken over.
    DisposableEffect(vm) { onDispose { nav.videoBounds = null; if (nav.top != app.streamsetu.tv.nav.Overlay.Player) vm.stopPlayback() } }
    SportsHubContent(state, actions, entry, restoreId, ScrollHolder(vm), nav.contentRestoreAllowed, returnTick, nav.sportsReturnToCard) { nav.sportsReturnToCard = false }
}

/** Where the list was scrolled, kept by the ViewModel (the screen is not composed while another tab is open). */
class ScrollHolder(private val vm: SportsViewModel) {
    var index: Int get() = vm.scrollIndex; set(v) { vm.scrollIndex = v }
    var offset: Int get() = vm.scrollOffset; set(v) { vm.scrollOffset = v }
}

/** The whole Hub as a function of its state. No database, no classification, no formatting: everything is already in [state]. */
@Composable
fun SportsHubContent(state: SportsHubUiState, actions: SportsActions, entry: FocusRequester, restoreId: String?, scroll: ScrollHolder, parentFocusEnabled: Boolean = true, returnTick: Int = 0, returnToCard: Boolean = false, onReturnedToCard: () -> Unit = {}) {
    val restore = remember { FocusRequester() }
    var restoring by remember { mutableStateOf(false) }
    val detailOpen = state.detail != null
    val covered = detailOpen || state.page != null
    // Closing the detail (or the page) puts the remote back on the event it came from (or the nearest one), by frames and with no timers.
    var wasOpen by remember { mutableStateOf(false) }
    LaunchedEffect(covered) {
        if (covered) { wasOpen = true; return@LaunchedEffect }
        if (!wasOpen) return@LaunchedEffect
        wasOpen = false
        if (restoreId != null) requestFocusOnFrames(8, { restore.requestFocus() }, { FocusMemory.focused === restore })
        else requestFocusOnFrames(8, { entry.requestFocus() }, { FocusMemory.focused === entry })
    }
    // Coming back to Sports after its stream was handed to Live TV: the remote goes to the remembered event, or the nearest one, or the filters. No timers: by frames.
    LaunchedEffect(returnToCard) {
        if (!returnToCard || detailOpen) return@LaunchedEffect
        if (restoreId != null) requestFocusOnFrames(8, { restore.requestFocus() }, { FocusMemory.focused === restore })
        else requestFocusOnFrames(8, { entry.requestFocus() }, { FocusMemory.focused === entry })
        onReturnedToCard()
    }
    Box(Modifier.fillMaxSize().testTag("sports-hub")) {
        // While the detail is open the Hub behind it cannot take the remote.
        CompositionLocalProvider(LocalFocusEnabled provides (parentFocusEnabled && !detailOpen)) {
            val page = state.page
            if (page != null) SportsPageView(page, state.pageDepth, detailOpen, actions) else Hub(state, actions, entry, restore, restoreId, scroll)
        }
        state.detail?.let { SportsDetailPanel(it, actions, returnTick) }
        state.manage?.let { SportsManagePanel(it, actions) }
        state.recordPanel?.let { SportsRecordPanel(it, actions) }
    }
}

@Composable
private fun Hub(state: SportsHubUiState, actions: SportsActions, entry: FocusRequester, restore: FocusRequester, restoreId: String?, scroll: ScrollHolder) {
    val hasFilters = state.filters.isNotEmpty()
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
        SportsHeader(state.refreshing, entry.takeIf { !hasFilters }, state.multiviewCount, state.hasFollows, actions.refresh, actions.openMultiview, actions.openManage)
        if (hasFilters) {
            SportsFilters(state.filters, state.selectedSport, state.mySports, entry, restore.takeIf { restoreId != null }, actions.select, actions.selectMy)
        }
        state.linkNotice?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(top = 6.dp).testTag("sports-link-notice")) }
        Spacer(Modifier.height(12.dp))
        val message = state.message
        when {
            state.loading && state.isEmpty -> SportsSkeleton()
            message != null -> SportsMessageView(message, actions)
            state.board != null -> SportsBoard(state.board, actions, entry, restore, restoreId, scroll)
            else -> SportsSections(state, actions, entry, restore, restoreId, scroll)
        }
    }
}

// ---- header and filters

@Composable
private fun SportsHeader(refreshing: Boolean, entry: FocusRequester?, multiview: Int, hasFollows: Boolean, onRefresh: () -> Unit, onMultiview: () -> Unit, onManage: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(bottom = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Label("Sports", Tokens.pageTitle, Tokens.text, FontWeight.Bold)
        if (refreshing) Label("Updating…", Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-refreshing"))
        Spacer(Modifier.weight(1f))
        if (hasFollows) TvButton("Manage My Sports", onManage, Modifier.testTag("sports-manage"))
        TvButton("Multiview" + if (multiview > 0) " ($multiview)" else "", onMultiview, Modifier.testTag("sports-multiview"))
        TvButton("Refresh", onRefresh, (if (entry != null) Modifier.focusRequester(entry) else Modifier).testTag("sports-refresh"), icon = Icons.Filled.Refresh)
    }
}

@Composable
private fun SportsFilters(filters: List<SportsFilter>, selected: Sport?, mySelected: Boolean, entry: FocusRequester, restore: FocusRequester?, onSelect: (Sport?) -> Unit, onSelectMy: () -> Unit) {
    Row(Modifier.fillMaxWidth().testTag("sports-filters").onPreviewKeyEvent { e ->
        // Down goes to the event the remote was last on, when it is on screen; otherwise the normal search below decides.
        if (restore != null && e.type == KeyEventType.KeyDown && e.key == Key.DirectionDown) runCatching { restore.requestFocus() }.isSuccess else false
    }) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(filters, key = { if (it.my) "my" else it.sport?.name ?: "all" }) { f ->
                val isSelected = if (f.my) mySelected else !mySelected && f.sport == selected
                SportsChip(f.label + (if (f.sport != null || f.my) "  ${f.count}" else ""), isSelected, if (isSelected) Modifier.focusRequester(entry) else Modifier, "sports-filter-${if (f.my) "MY" else f.sport?.name ?: "ALL"}") { if (f.my) onSelectMy() else onSelect(f.sport) }
            }
        }
    }
}

@Composable
private fun SportsChip(label: String, selected: Boolean, modifier: Modifier, tag: String, onClick: () -> Unit) {
    // Focus alone never selects: only OK does.
    Focusable(onClick, modifier.testTag(tag), shape = RoundedCornerShape(50), container = if (selected) Tokens.accent.copy(alpha = 0.22f) else Tokens.elevated, scaleOnFocus = 1.05f) { _ ->
        Label(label, Tokens.small, Tokens.text, if (selected) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp))
    }
}

// ---- sections

@Composable
private fun SportsSections(state: SportsHubUiState, actions: SportsActions, entry: FocusRequester, restore: FocusRequester, restoreId: String?, scroll: ScrollHolder) {
    val list = rememberLazyListState(scroll.index, scroll.offset)
    // The scroll position is saved when the screen goes away.
    DisposableEffect(list) { onDispose { scroll.index = list.firstVisibleItemIndex; scroll.offset = list.firstVisibleItemScrollOffset } }
    val sections = state.sections
    // The cards of earlier sections come first, so every card knows its position among all of them.
    val starts = remember(state.live, state.startingSoon, state.today, state.upcoming) {
        var n = 0; SportsSection.values().associateWith { s -> n.also { n += state.section(s).size } }
    }
    LazyColumn(Modifier.fillMaxSize().testTag("sports-list"), list, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        items(sections, key = { it.name }) { s ->
            SportsSectionRail(s.name, s.title, state.section(s), starts.getValue(s), restore, restoreId, entry.takeIf { s == sections.first() }, actions.open, actions.remember)
        }
    }
}

/** My Sports: the followed things in the order that matters most, each event once. */
@Composable
private fun SportsBoard(board: app.streamsetu.tv.sports.discovery.MyBoardUi, actions: SportsActions, entry: FocusRequester, restore: FocusRequester, restoreId: String?, scroll: ScrollHolder) {
    val list = rememberLazyListState(scroll.index, scroll.offset)
    DisposableEffect(list) { onDispose { scroll.index = list.firstVisibleItemIndex; scroll.offset = list.firstVisibleItemScrollOffset } }
    val starts = remember(board) { var n = 0; board.sections.associate { s -> s.id to n.also { n += s.cards.size } } }
    LazyColumn(Modifier.fillMaxSize().testTag("sports-list"), list, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        items(board.sections, key = { it.id }) { s ->
            SportsSectionRail(s.id, s.title, s.cards, starts.getValue(s.id), restore, restoreId, entry.takeIf { s === board.sections.first() }, actions.open, actions.remember)
        }
        if (board.recordings.isNotEmpty()) item(key = "board-recordings") { RecordingRows(board.recordings, actions, "sports-board-recordings") }
    }
}

/** Recordings that are listed on a page or in My Sports. A row you can act on (watch the recording, open its event) takes the remote; a row you cannot is only text. */
@Composable
private fun RecordingRows(rows: List<app.streamsetu.tv.sports.discovery.PageRecordingUi>, actions: SportsActions, tag: String) {
    Column(Modifier.testTag(tag), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Label("Recordings", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 2.dp))
        rows.forEach { r ->
            val act: (() -> Unit)? = if (r.playId != null) ({ actions.watchRecording(r.playId) }) else r.eventId?.let { id -> ({ actions.open(id) }) }
            val text = r.line + when { r.playId != null -> "  ·  OK to watch"; r.eventId != null -> "  ·  OK to open the event"; else -> "" }
            if (act != null) Focusable(act, Modifier.fillMaxWidth().widthIn(max = 860.ui).testTag("sports-recording-row-${r.id}"), shape = RoundedCornerShape(Tokens.radiusSmall), scaleOnFocus = 1.0f) {
                Label(text, Tokens.small, Tokens.text, maxLines = 2, modifier = Modifier.padding(12.dp))
            } else Label(text, Tokens.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.padding(12.dp).testTag("sports-recording-row-${r.id}"))
        }
    }
}

/** A team's or a competition's page. Only what the guide and the person's own records say; nothing is looked up. */
@Composable
private fun SportsPageView(page: app.streamsetu.tv.sports.discovery.SportsPageUi, depth: Int, detailOpen: Boolean, actions: SportsActions) {
    val close = remember { FocusRequester() }
    val restore = remember { FocusRequester() }
    var last by remember(page.ref) { mutableStateOf<String?>(null) }
    val ids = page.allCardIds
    val restoreId = last?.takeIf { it in ids } ?: ids.getOrNull((ids.indexOf(last).takeIf { it >= 0 } ?: 0).coerceAtMost(ids.lastIndex)) ?: ids.firstOrNull()     // the card it was on, else the nearest, else the first
    var wasOpen by remember { mutableStateOf(false) }
    // Opening: the remote goes to the first event, or to Close when there is none. Coming back from an event: to the card it came from. By frames, no timers.
    LaunchedEffect(page.ref, detailOpen) {
        if (detailOpen) { wasOpen = true; return@LaunchedEffect }
        wasOpen = false
        if (restoreId != null) requestFocusOnFrames(8, { restore.requestFocus() }, { FocusMemory.focused === restore }) else requestFocusOnFrames(8, { close.requestFocus() }, { FocusMemory.focused === close })
    }
    val list = rememberLazyListState()
    val starts = remember(page) { var n = 0; page.sections.associate { s -> s.id to n.also { n += s.cards.size } } }
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical).testTag("sports-page")) {
        Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(Modifier.weight(1f)) {
                Label(page.ref.name, Tokens.pageTitle, Tokens.text, FontWeight.Bold, maxLines = 2, modifier = Modifier.testTag("sports-page-title"))
                Label(page.sportLabel + "  ·  " + (if (page.ref.kind == app.streamsetu.tv.sports.discovery.PageKind.TEAM) "Team" else "Competition"), Tokens.body, Tokens.textSecondary, maxLines = 1)
            }
            if (page.canFollow) TvButton(if (page.following) "Following  ·  Unfollow" else "Follow", { if (page.following) actions.unfollowPage(page.ref) else actions.followPage(page.ref) }, Modifier.testTag("sports-page-follow"))
            TvButton("Close", { actions.closePageUi() }, Modifier.focusRequester(close).testTag("sports-page-close"), icon = Icons.Filled.Close)
        }
        page.note?.let { Label(it, Tokens.small, Tokens.warning, modifier = Modifier.padding(bottom = 4.dp).testTag("sports-page-note")) }
        val meta = listOfNotNull(page.channelCount.takeIf { it > 0 }?.let { "$it channel" + if (it == 1) "" else "s" }, page.reminderCount.takeIf { it > 0 }?.let { "$it reminder" + if (it == 1) "" else "s" }).joinToString("  ·  ")
        if (meta.isNotEmpty()) Label(meta, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-page-meta"))
        if (page.catchUpLoading) Label("Loading Catch-Up…", Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(top = 4.dp).testTag("sports-page-loading"))
        Spacer(Modifier.height(10.dp))
        if (page.isEmpty) {
            Column(Modifier.fillMaxWidth().testTag("sports-page-empty"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label("Nothing in your guide right now", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("No live or upcoming events for this are in the current guide. Recordings and reminders you make for it will appear here.", Tokens.body, Tokens.textSecondary, modifier = Modifier.fillMaxWidth(0.6f))
            }
        } else LazyColumn(Modifier.fillMaxSize().testTag("sports-page-list"), list, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            items(page.sections, key = { it.id }) { s ->
                SportsSectionRail(s.id, s.title, s.cards, starts.getValue(s.id), restore, restoreId, close.takeIf { s === page.sections.first() }, actions.open) { id, _ -> last = id }
            }
            if (page.recordings.isNotEmpty()) item(key = "page-recordings") { RecordingRows(page.recordings, actions, "sports-page-recordings") }
        }
    }
}

/** One section on its own: moving the remote inside it recomposes this and nothing else. */
@Composable
private fun SportsSectionRail(id: String, title: String, cards: List<SportsEventCard>, firstIndex: Int, restore: FocusRequester, restoreId: String?, upTo: FocusRequester?, open: (String) -> Unit, remember: (String, Int) -> Unit) {
    // Starts on the remembered event when it is in this section, so it is composed and can take the remote at once.
    val at = cards.indexOfFirst { it.id == restoreId }.coerceAtLeast(0)
    val row: LazyListState = rememberLazyListState(initialFirstVisibleItemIndex = at)
    Column(Modifier.testTag("sports-section-$id")) {
        Label(title, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 8.dp))
        LazyRow(state = row, horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 6.dp)) {
            items(cards, key = { it.id }) { card ->
                val index = firstIndex + cards.indexOf(card)
                SportsEventCardView(card, (if (card.id == restoreId) Modifier.focusRequester(restore) else Modifier).then(if (upTo != null) Modifier.focusProperties { up = upTo } else Modifier), { open(card.id) }) { focused -> if (focused) remember(card.id, index) }
            }
        }
    }
}

@Composable
private fun SportsEventCardView(card: SportsEventCard, modifier: Modifier, onOpen: () -> Unit, onFocus: (Boolean) -> Unit) {
    Focusable(onOpen, modifier.width(300.ui).testTag("sports-card-${card.id}"), shape = RoundedCornerShape(Tokens.radius), onFocus = onFocus) { _ ->
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (card.logoUrl != null) ChannelLogo(card.logoUrl, card.title, 40.ui)
                else Box(Modifier.size(40.ui).background(Tokens.elevated, RoundedCornerShape(Tokens.radius)), Alignment.Center) {
                    Image(sportIcon(card.sport), card.sportLabel, Modifier.size(24.ui), colorFilter = ColorFilter.tint(Tokens.textSecondary))
                }
                Column(Modifier.weight(1f)) {
                    Label(card.sportLabel + (card.competition?.let { " · $it" } ?: ""), Tokens.caption, Tokens.textSecondary, maxLines = 1)
                    Label(card.statusLabel, Tokens.caption, if (card.live) Tokens.accent else Tokens.textSecondary, FontWeight.Bold, maxLines = 1)
                }
            }
            Label(card.title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.height(48.ui))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(card.timeLabel, Tokens.small, Tokens.textSecondary, maxLines = 1)
                if (card.feedCount > 1) Label("${card.feedCount} channels", Tokens.small, Tokens.textSecondary, maxLines = 1)
                if (card.catchUp) Label("Catch-up", Tokens.small, Tokens.textSecondary, maxLines = 1)
                if (card.reminded) Label("Reminder set", Tokens.small, Tokens.accent, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.testTag("sports-reminded"))
            }
            card.reason?.let { Label(it, Tokens.caption, Tokens.textSecondary, maxLines = 1, modifier = Modifier.testTag("sports-reason")) }
            card.recordingLabel?.let { Label(it, Tokens.caption, Tokens.accent, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.testTag("sports-recording-mark")) }
        }
    }
}

private fun sportIcon(s: Sport): ImageVector = when (s) {
    Sport.FOOTBALL -> Icons.Filled.SportsSoccer; Sport.CRICKET -> Icons.Filled.SportsCricket; Sport.BASKETBALL -> Icons.Filled.SportsBasketball
    Sport.AMERICAN_FOOTBALL -> Icons.Filled.SportsFootball; Sport.BASEBALL -> Icons.Filled.SportsBaseball; Sport.ICE_HOCKEY -> Icons.Filled.SportsHockey
    Sport.TENNIS -> Icons.Filled.SportsTennis; Sport.MOTORSPORT -> Icons.Filled.SportsMotorsports; Sport.GOLF -> Icons.Filled.SportsGolf
    Sport.BOXING, Sport.MMA -> Icons.Filled.SportsMma; Sport.RUGBY -> Icons.Filled.SportsRugby
}

// ---- states

@Composable
private fun SportsSkeleton() {
    Column(Modifier.fillMaxSize().testTag("sports-skeleton"), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        repeat(2) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.width(160.ui).height(20.ui).background(Tokens.elevated, RoundedCornerShape(6.dp)))
                Row(horizontalArrangement = Arrangement.spacedBy(Tokens.gutter)) { repeat(4) { Box(Modifier.width(300.ui).height(150.ui).background(Tokens.card, RoundedCornerShape(Tokens.radius))) } }
            }
        }
    }
}

@Composable
private fun SportsMessageView(message: SportsHubMessage, actions: SportsActions) {
    Column(Modifier.fillMaxSize().testTag("sports-message"), Arrangement.Center, Alignment.CenterHorizontally) {
        when (message) {
            is SportsHubMessage.Error -> {
                Label("Sports could not be loaded", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label(message.text, Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 8.dp, bottom = 20.dp))
                TvButton("Retry", actions.refresh, Modifier.testTag("sports-retry"), icon = Icons.Filled.Refresh, primary = true)
            }
            SportsHubMessage.NoGuide -> {
                Label("No guide yet", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("Sports events come from your playlist's programme guide, and none has been read for this library.", Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 8.dp, bottom = 20.dp).fillMaxWidth(0.6f))
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) { MessageActions(actions) }
            }
            SportsHubMessage.NoFollowed -> {
                Label("Nothing from My Sports right now", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("No events from your followed sports are in the current guide window.", Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 8.dp, bottom = 20.dp).fillMaxWidth(0.6f))
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    TvButton("View All Sports", { actions.select(null) }, Modifier.testTag("sports-view-all"), primary = true)
                    TvButton("Manage My Sports", actions.openManage, Modifier.testTag("sports-manage-from-empty"))
                }
            }
            SportsHubMessage.NoSports -> {
                Label("No sports events", Tokens.title, Tokens.text, FontWeight.SemiBold)
                Label("No sports events were found in your guide. Sports appear here when your playlist guide identifies live or upcoming events.", Tokens.body, Tokens.textSecondary, modifier = Modifier.padding(top = 8.dp, bottom = 20.dp).fillMaxWidth(0.6f))
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) { MessageActions(actions) }
            }
        }
    }
}

@Composable
private fun MessageActions(actions: SportsActions) {
    TvButton("Refresh Guide", actions.refreshGuide, Modifier.testTag("sports-refresh-guide"), primary = true)
    TvButton("Open Guide Settings", actions.openGuideSettings, Modifier.testTag("sports-guide-settings"))
    TvButton("View Sports Channels", actions.viewSportsChannels, Modifier.testTag("sports-channels"))
}

// ---- detail

/** A read-only panel over the Hub. The feed rows only inform: playback from Sports comes in a later phase. */
@Composable
private fun SportsDetailPanel(d: SportsEventDetail, actions: SportsActions, returnTick: Int) {
    val close = remember { FocusRequester() }
    val best = remember { FocusRequester() }
    var closeFocused by remember { mutableStateOf(false) }
    val rows = remember(d.card.id) { HashMap<String, FocusRequester>() }
    val play = d.playback
    val showPreview = play != null && play.status != app.streamsetu.tv.sports.SportsPlayStatus.IDLE
    var feedMenu by remember(d.card.id) { mutableStateOf<SportsFeedRow?>(null) }
    feedMenu?.let { f ->
        app.streamsetu.tv.ui.components.ContextMenu(f.channelName, f.sourceName, listOf(
            app.streamsetu.tv.ui.components.MenuAction("Watch this feed", Icons.Filled.PlayArrow) { actions.watchFeed(f.channelId) },
            app.streamsetu.tv.ui.components.MenuAction("Add to Multiview", Icons.Filled.Add) { actions.addFeedToMultiview(f.channelId) },
        ), onClose = { feedMenu = null })
    }
    LaunchedEffect(d.card.id) { requestFocusOnFrames(8, { close.requestFocus() }, { closeFocused }) }
    // Back from the embedded picture: the remote returns to the feed that is playing, or to Watch Best Feed.
    LaunchedEffect(returnTick) {
        if (returnTick == 0) return@LaunchedEffect
        val target = d.feeds.firstOrNull { it.current }?.channelId?.let { rows[it] } ?: best
        runCatching { target.requestFocus() }
    }
    Row(Modifier.fillMaxSize().testTag("sports-detail")) {
        Box(Modifier.weight(1f).fillMaxHeight().background(app.streamsetu.tv.ui.theme.Tokens.pick(androidx.compose.ui.graphics.Color(0x99000000), app.streamsetu.tv.ui.theme.Tokens.scrimStrong)), Alignment.Center) {
            if (showPreview) SportsPreview(actions)
        }
        Column(Modifier.width(560.ui).fillMaxHeight().background(Tokens.panel).padding(horizontal = 28.dp, vertical = Tokens.safeVertical).focusGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (d.heldChannel != null) { SportsHeldBody(d, actions, close, best, { closeFocused = it }); return@Column }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Label(d.card.title, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 3, modifier = Modifier.weight(1f))
                TvButton("Close", actions.closeDetail, Modifier.focusRequester(close).testTag("sports-detail-close"), icon = Icons.Filled.Close, onFocus = { closeFocused = it })
            }
            Label(d.card.sportLabel + (d.card.competition?.let { " · $it" } ?: ""), Tokens.body, Tokens.textSecondary)
            Label(d.timeRange, Tokens.body, Tokens.text)
            Label(d.stateLabel, Tokens.body, if (d.card.live) Tokens.accent else Tokens.textSecondary, FontWeight.SemiBold)
            if (d.lowConfidence) Label("This listing was matched with lower confidence, so the details may be wrong.", Tokens.small, Tokens.warning, modifier = Modifier.testTag("sports-low-confidence"))
            // Everything below the title scrolls as one list, so the buttons, the follow choices and the feeds all stay reachable on a short screen.
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (d.feeds.isNotEmpty()) item(key = "watch") {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton("Watch Best Feed", actions.watchBest, Modifier.focusRequester(best).testTag("sports-watch-best"), icon = Icons.Filled.PlayArrow, primary = true)
                        d.bestLabel?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-best-label")) }
                        TvButton("Add to Multiview", actions.addToMultiview, Modifier.testTag("sports-add-multiview"), icon = Icons.Filled.Add)
                        d.multiviewNote?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-multiview-note")) }
                    }
                }
                item(key = "personal") {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SportsReminderBlock(d.reminder, actions)
                        d.followOptions.forEach { o ->
                            TvButton(if (o.following) "Following ${o.name}  ·  Unfollow" else o.label, {
                                if (o.following) actions.unfollow(app.streamsetu.tv.sports.personal.Follow(o.kind, o.sport, o.key, o.name))
                                else actions.follow(o.kind, o.name)
                            }, Modifier.testTag("sports-follow-${o.kind.name}-${app.streamsetu.tv.sports.personal.SportsKeys.key(o.name)}"))
                        }
                    }
                }
                item(key = "pages") {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        d.pageLinks.forEach { l -> TvButton(l.label, { actions.openPage(l.ref) }, Modifier.testTag("sports-page-link-${l.ref.kind.name}-${app.streamsetu.tv.sports.personal.SportsKeys.key(l.ref.name)}")) }
                        if (d.card.id != "held") TvButton("Open Guide", actions.openGuide, Modifier.testTag("sports-open-guide"))
                    }
                }
                item(key = "recording") { SportsRecordingBlock(d, actions) }
                if (play != null) item(key = "playnote") { SportsPlaybackNote(play, d, actions, rows) }
                item(key = "feeds-title") { Label("Available feeds", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp)) }
                items(d.feeds.size, key = { "f-" + d.feeds[it].channelId.ifEmpty { it.toString() } }) { i ->
                    val f = d.feeds[i]
                    SportsFeedRowView(f, if (f.channelId.isNotEmpty()) Modifier.focusRequester(rows.getOrPut(f.channelId) { FocusRequester() }) else Modifier, onMenu = { if (f.channelId.isNotEmpty()) feedMenu = f }) { if (f.channelId.isNotEmpty()) actions.watchFeed(f.channelId) }
                }
            }
        }
    }
}

/** The panel for a channel that keeps playing after its event left the guide. The picture above stays where it was; the choices are Live TV's embedded player or Stop. */
@Composable
private fun androidx.compose.foundation.layout.ColumnScope.SportsHeldBody(d: SportsEventDetail, actions: SportsActions, close: FocusRequester, primary: FocusRequester, onCloseFocus: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Label(d.heldChannel.orEmpty(), Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 3, modifier = Modifier.weight(1f))
        TvButton("Close", actions.closeDetail, Modifier.focusRequester(close).testTag("sports-detail-close"), icon = Icons.Filled.Close, onFocus = onCloseFocus)
    }
    Label("The guide changed. This channel is still playing.", Tokens.body, Tokens.text, FontWeight.SemiBold, modifier = Modifier.testTag("sports-held-notice"))
    Label("It is no longer listed as a Sports event. Open it in Live TV to keep watching, or stop it.", Tokens.small, Tokens.textSecondary)
    TvButton("Open in Live TV", actions.closeDetail, Modifier.focusRequester(primary).testTag("sports-held-live"), icon = Icons.Filled.PlayArrow, primary = true)
    TvButton("Stop", actions.stopHeld, Modifier.testTag("sports-held-stop"))
}

/** The embedded picture: the one video surface is placed on this box (see PersistentVideo); OK opens the existing fullscreen player. */
@Composable
private fun SportsPreview(actions: SportsActions) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
        val w = minOf(maxWidth, maxHeight * 16f / 9f); val h = w * 9f / 16f
        DisposableEffect(Unit) { onDispose { actions.previewBounds(null) } }
        Focusable({ actions.openFullscreen() }, Modifier.size(w, h).testTag("sports-preview").onFocusChanged { actions.previewFocused(it.hasFocus) }.onGloballyPositioned { actions.previewBounds(it.boundsInWindow()) },
            scaleOnFocus = 1.0f, container = androidx.compose.ui.graphics.Color.Black, shape = RoundedCornerShape(16.dp), ringWidth = 3.dp) {
            Box(Modifier.fillMaxSize())
        }
    }
}

/** What the playback says under Watch Best Feed: a concise failure with its three choices, or a short line while it starts. */
@Composable
private fun SportsPlaybackNote(play: SportsDetailPlayback, d: SportsEventDetail, actions: SportsActions, rows: Map<String, FocusRequester>) {
    val failed = play.status == app.streamsetu.tv.sports.SportsPlayStatus.FAILED
    if (play.message != null) {
        Column(Modifier.fillMaxWidth().testTag("sports-play-error"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label(play.message, Tokens.body, Tokens.warning, FontWeight.SemiBold)
            if (failed) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton("Try Again", actions.retryPlayback, Modifier.testTag("sports-try-again"))
                if (d.feeds.size > 1) TvButton("Choose Another Feed", {
                    val target = d.feeds.firstOrNull { it.suggested }?.channelId ?: d.feeds.firstOrNull { !it.failed }?.channelId
                    target?.let { rows[it] }?.let { r -> runCatching { r.requestFocus() } }
                }, Modifier.testTag("sports-choose-another"))
                TvButton("Back to Event", actions.backToEvent, Modifier.testTag("sports-back-to-event"))
            }
        }
    } else if (play.status == app.streamsetu.tv.sports.SportsPlayStatus.STARTING) {
        Label("Starting…", Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-starting"))
    }
}

@Composable
private fun SportsFeedRowView(f: SportsFeedRow, modifier: Modifier, onMenu: () -> Unit, onPlay: () -> Unit) {
    // OK plays this exact feed. Focus alone does nothing.
    Focusable(onPlay, modifier.fillMaxWidth().testTag("sports-feed"), shape = RoundedCornerShape(Tokens.radiusSmall), container = Tokens.card, scaleOnFocus = 1.0f, focusSound = null, selectSound = null, onLongClick = onMenu) { _ ->
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Label(f.channelName + "  ·  " + f.sourceName, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1)
            val parts = ArrayList<String>()
            f.language?.let { parts.add("Language: ${it.text}" + (if (it.inferred) " (inferred)" else "")) }
            f.quality?.let { parts.add("Quality: ${it.text}" + (if (it.inferred) " (inferred)" else "")) }
            if (f.catchUp) parts.add("Catch-up available")
            if (parts.isNotEmpty()) Label(parts.joinToString("  ·  "), Tokens.small, Tokens.textSecondary, maxLines = 2)
            val tags = ArrayList<String>()
            if (f.current) tags.add("Playing now") 
            if (f.recommended) tags.add("Recommended")
            if (f.failed) tags.add("Could not play")
            if (f.suggested) tags.add("Next best: press OK to switch")
            if (f.unsupported) tags.add("This device may not show this quality")
            if (tags.isNotEmpty()) Label(tags.joinToString("  ·  "), Tokens.small, if (f.failed) Tokens.warning else Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("sports-feed-tags"))
        }
    }
}


// ---- reminders and My Sports management

/** Remind Me, and what is set: the choice of lead time, Change and Remove, and what to do when the event left the guide. */
@Composable
private fun SportsReminderBlock(r: ReminderUi?, actions: SportsActions) {
    var menu by remember(r?.id) { mutableStateOf(false) }
    if (r == null) {
        TvButton("Remind Me", { menu = true }, Modifier.testTag("sports-remind"), icon = Icons.Filled.Add)
    } else if (r.unavailable) {
        Column(Modifier.fillMaxWidth().testTag("sports-reminder-unavailable"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Label("Schedule unavailable", Tokens.body, Tokens.warning, FontWeight.SemiBold)
            Label("The event is no longer in the current guide.", Tokens.small, Tokens.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton("Keep Reminder", { actions.keepReminder(r.id) }, Modifier.testTag("sports-reminder-keep"))
                TvButton("Remove", { actions.removeReminder(r.id) }, Modifier.testTag("sports-reminder-remove"))
            }
        }
    } else {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Label(r.text + "  ·  " + r.startLabel, Tokens.small, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("sports-reminder-set"))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton("Change Reminder", { menu = true }, Modifier.testTag("sports-reminder-change"))
                TvButton("Remove Reminder", { actions.removeReminder(r.id) }, Modifier.testTag("sports-reminder-remove"))
            }
        }
    }
    if (menu) app.streamsetu.tv.ui.components.ContextMenu("Remind me", null, app.streamsetu.tv.sports.personal.ReminderLeads.OPTIONS.map { lead ->
        app.streamsetu.tv.ui.components.MenuAction(app.streamsetu.tv.sports.personal.ReminderLeads.label(lead) + if (lead == app.streamsetu.tv.sports.personal.ReminderLeads.DEFAULT_MS) "  (default)" else "", Icons.Filled.PlayArrow) { if (r == null) actions.remind(lead) else actions.changeReminder(r.id, lead) }
    }, onClose = { menu = false })
}

/** Manage My Sports: what is followed (sports, competitions, teams and participants) and the reminders, with Unfollow and a confirmed Clear all. */
@Composable
private fun SportsManagePanel(m: ManageUi, actions: SportsActions) {
    val first = remember { FocusRequester() }
    var confirm by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { requestFocusOnFrames(8, { first.requestFocus() }, { false }) }
    Row(Modifier.fillMaxSize().testTag("sports-manage-panel")) {
        Spacer(Modifier.weight(1f).fillMaxHeight().background(app.streamsetu.tv.ui.theme.Tokens.pick(androidx.compose.ui.graphics.Color(0x99000000), app.streamsetu.tv.ui.theme.Tokens.scrimStrong)))
        Column(Modifier.width(560.ui).fillMaxHeight().background(Tokens.panel).padding(horizontal = 28.dp, vertical = Tokens.safeVertical).focusGroup(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Label("Manage My Sports", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.weight(1f))
                TvButton("Close", actions.closeManage, Modifier.focusRequester(first).testTag("sports-manage-close"), icon = Icons.Filled.Close)
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                manageSection("Sports", m.sports, actions, m)
                manageSection("Competitions", m.competitions, actions, m)
                manageSection("Teams and participants", m.participants, actions, m)
                if (m.reminders.isNotEmpty()) {
                    item(key = "h-rem") { Label("Reminders", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp)) }
                    items(m.reminders.size, key = { "r-" + m.reminders[it].id }) { i ->
                        val r = m.reminders[i]
                        var ask by remember(r.id) { mutableStateOf(false) }
                        Focusable({ if (r.unavailable) ask = true else actions.removeReminder(r.id) }, Modifier.fillMaxWidth().testTag("sports-manage-reminder-${r.id}"), shape = RoundedCornerShape(Tokens.radiusSmall), scaleOnFocus = 1.0f) {
                            Label(r.startLabel + "  ·  " + (if (r.unavailable) "Schedule unavailable. The event is no longer in the current guide." else r.text + "  ·  OK to remove"), Tokens.small, Tokens.text, maxLines = 3, modifier = Modifier.padding(12.dp))
                        }
                        if (ask) app.streamsetu.tv.ui.components.ContextMenu("Schedule unavailable", "The event is no longer in the current guide.", listOf(
                            app.streamsetu.tv.ui.components.MenuAction("Keep Reminder", Icons.Filled.PlayArrow) { actions.keepReminder(r.id) },
                            app.streamsetu.tv.ui.components.MenuAction("Remove", Icons.Filled.Close, danger = true) { actions.removeReminder(r.id) },
                        ), onClose = { ask = false })
                    }
                }
            }
            if (m.sports.isNotEmpty() || m.competitions.isNotEmpty() || m.participants.isNotEmpty()) TvButton("Clear all", { confirm = true }, Modifier.testTag("sports-manage-clear"))
        }
    }
    if (confirm) app.streamsetu.tv.ui.components.ContextMenu("Stop following everything?", "Reminders stay as they are.", listOf(
        app.streamsetu.tv.ui.components.MenuAction("Clear all", Icons.Filled.Close, danger = true) { actions.clearFollows() },
        app.streamsetu.tv.ui.components.MenuAction("Cancel", Icons.Filled.Close) {},
    ), onClose = { confirm = false })
}

private fun androidx.compose.foundation.lazy.LazyListScope.manageSection(title: String, rows: List<app.streamsetu.tv.sports.personal.Follow>, actions: SportsActions, m: ManageUi) {
    if (rows.isEmpty()) return
    item(key = "h-$title") { Label(title, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp)) }
    items(rows.size, key = { "f-$title-" + rows[it].sport.name + rows[it].key }) { i ->
        val f = rows[i]
        val id = ManageUi.manageId(f); val choices = m.choices[id]
        var choose by remember(id) { mutableStateOf(false) }
        Focusable({ if (choices != null) choose = true else actions.unfollow(f) }, Modifier.fillMaxWidth().testTag("sports-manage-follow-${f.kind.name}-${f.key}"), shape = RoundedCornerShape(Tokens.radiusSmall), scaleOnFocus = 1.0f) {
            val what = if (f.kind == app.streamsetu.tv.sports.personal.FollowKind.COMPETITION) "competition" else "team"
            Label(f.displayName + "  ·  " + f.sport.title + "  ·  " + when { choices != null -> "Choose the $what"; id in m.unavailable -> "Not in the guide right now  ·  OK to unfollow"; else -> "OK to unfollow" }, Tokens.small, Tokens.text, maxLines = 2, modifier = Modifier.padding(12.dp))
        }
        if (choose && choices != null) app.streamsetu.tv.ui.components.ContextMenu(f.displayName, "More than one fits. Until you choose, nothing is followed under this name.", choices.map { ch ->
            app.streamsetu.tv.ui.components.MenuAction(ch.label, Icons.Filled.PlayArrow) { actions.chooseFollow(f, ch.key) }
        } + app.streamsetu.tv.ui.components.MenuAction("Stop following", Icons.Filled.Close, danger = true) { actions.unfollow(f) }, onClose = { choose = false })
    }
}


// ---- recording, start over and catch-up

/** The actions that are valid for this event right now, and only those: Record, Cancel, Stop, Watch Recording, Review Schedule, Start Over, Watch Catch-Up. Watch Live is Watch Best Feed above. */
@Composable
private fun SportsRecordingBlock(d: SportsEventDetail, actions: SportsActions) {
    if (d.card.id == "held") return
    var confirm by remember(d.card.id, d.recording?.id, d.recording?.status) { mutableStateOf<String?>(null) }
    var pick by remember(d.card.id) { mutableStateOf<Boolean?>(null) }                      // true: Start Over, false: Catch-Up
    val r = d.recording; val a = d.abilities
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (r != null) {
            Label(r.line, Tokens.small, if (r.review) Tokens.warning else Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("sports-recording-line"))
            if (r.canCancel && !r.review) TvButton("Cancel Recording", { confirm = "cancel" }, Modifier.testTag("sports-recording-cancel"))
            if (r.canStop) TvButton("Stop Recording", { confirm = "stop" }, Modifier.testTag("sports-recording-stop"))
            if (r.playId != null) TvButton("Watch Recording", { actions.watchRecording(r.playId) }, Modifier.testTag("sports-recording-watch"), icon = Icons.Filled.PlayArrow)
            if (r.review) TvButton("Review Schedule", { confirm = "review" }, Modifier.testTag("sports-recording-review"))
        } else if (a != null && a.canRecord) {
            TvButton(if (d.card.live) "Record Now" else "Record", actions.openRecord, Modifier.testTag("sports-record"))
        } else a?.recordHint?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-record-hint")) }
        if (d.startOver.isNotEmpty()) TvButton("Start Over", { if (d.startOver.size == 1) actions.startOver(d.startOver[0].channelId) else pick = true }, Modifier.testTag("sports-start-over"), icon = Icons.Filled.PlayArrow)
        if (d.catchUp.isNotEmpty()) TvButton("Watch Catch-Up", { if (d.catchUp.size == 1) actions.watchCatchUp(d.catchUp[0].channelId) else pick = false }, Modifier.testTag("sports-catch-up"), icon = Icons.Filled.PlayArrow)
    }
    when (confirm) {
        "cancel" -> if (r != null) app.streamsetu.tv.ui.components.ContextMenu("Cancel this recording?", "Nothing has been recorded yet.", listOf(
            app.streamsetu.tv.ui.components.MenuAction("Cancel Recording", Icons.Filled.Close, danger = true) { actions.cancelRecording(r.id) }, app.streamsetu.tv.ui.components.MenuAction("Keep it", Icons.Filled.PlayArrow) {}), onClose = { confirm = null })
        "stop" -> if (r != null) app.streamsetu.tv.ui.components.ContextMenu("Stop recording?", "What has been recorded so far is kept in Recordings.", listOf(
            app.streamsetu.tv.ui.components.MenuAction("Stop Recording", Icons.Filled.Close, danger = true) { actions.stopRecording(r.id) }, app.streamsetu.tv.ui.components.MenuAction("Keep recording", Icons.Filled.PlayArrow) {}), onClose = { confirm = null })
        "review" -> if (r != null) app.streamsetu.tv.ui.components.ContextMenu("Schedule changed", "The guide now shows this event differently, so it is not recorded until it is clear which showing it is. It is restored by itself if that becomes clear.", listOf(
            app.streamsetu.tv.ui.components.MenuAction("Cancel Recording", Icons.Filled.Close, danger = true) { actions.cancelRecording(r.id) }, app.streamsetu.tv.ui.components.MenuAction("Keep waiting", Icons.Filled.PlayArrow) {}), onClose = { confirm = null })
    }
    pick?.let { startOver ->
        val choices = if (startOver) d.startOver else d.catchUp
        app.streamsetu.tv.ui.components.ContextMenu(if (startOver) "Start over on" else "Catch-up on", null, choices.map { ch ->
            app.streamsetu.tv.ui.components.MenuAction(ch.label, Icons.Filled.PlayArrow) { if (startOver) actions.startOver(ch.channelId) else actions.watchCatchUp(ch.channelId) }
        }, onClose = { pick = null })
    }
}

/** What will be recorded, when, for how long, the estimate and anything in the way, before the person confirms. Nothing is cancelled or replaced to make room. */
@Composable
private fun SportsRecordPanel(p: RecordPanelUi, actions: SportsActions) {
    val first = remember { FocusRequester() }
    var feedMenu by remember { mutableStateOf(false) }
    LaunchedEffect(p.eventId) { requestFocusOnFrames(8, { first.requestFocus() }, { false }) }
    Row(Modifier.fillMaxSize().testTag("sports-record-panel")) {
        Spacer(Modifier.weight(1f).fillMaxHeight().background(app.streamsetu.tv.ui.theme.Tokens.pick(androidx.compose.ui.graphics.Color(0x99000000), app.streamsetu.tv.ui.theme.Tokens.scrimStrong)))
        Column(Modifier.width(560.ui).fillMaxHeight().background(Tokens.panel).padding(horizontal = 28.dp, vertical = Tokens.safeVertical).focusGroup(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label(if (p.recordNow) "Record now" else "Record this event", Tokens.title, Tokens.text, FontWeight.Bold)
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item { Label(p.timeLabel, Tokens.body, Tokens.text, modifier = Modifier.testTag("sports-record-time")) }
                item { Label("Recording for about " + p.durationLabel, Tokens.small, Tokens.textSecondary) }
                p.feeds.firstOrNull { it.channelId == p.chosen }?.let { f -> item { Label("Feed: " + f.label, Tokens.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.testTag("sports-record-feed")) } }
                if (p.feeds.size > 1) item { TvButton("Choose another feed", { feedMenu = true }, Modifier.testTag("sports-record-change-feed")) }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton("Before: ${p.preMin} min", { actions.recordPadding(nextOf(listOf(0, 1, 5, 10), p.preMin), p.postMin) }, Modifier.testTag("sports-record-pre"))
                        TvButton("After: ${p.postMin} min", { actions.recordPadding(p.preMin, nextOf(listOf(0, 5, 10, 30), p.postMin)) }, Modifier.testTag("sports-record-post"))
                    }
                }
                p.storageLabel?.let { item { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-record-storage")) } }
                p.freeLabel?.let { item { Label(it, Tokens.small, Tokens.textSecondary) } }
                p.problems.forEach { t -> item { Label(t, Tokens.small, Tokens.warning, FontWeight.SemiBold, modifier = Modifier.testTag("sports-record-problem")) } }
                p.notes.forEach { t -> item { Label(t, Tokens.small, Tokens.textSecondary) } }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (p.canConfirm) TvButton(if (p.recordNow) "Start Recording" else "Schedule Recording", actions.confirmRecord, Modifier.focusRequester(first).testTag("sports-record-confirm"), primary = true)
                TvButton("Cancel", actions.closeRecord, (if (p.canConfirm) Modifier else Modifier.focusRequester(first)).testTag("sports-record-close"))
            }
        }
    }
    if (feedMenu) app.streamsetu.tv.ui.components.ContextMenu("Record from", null, p.feeds.map { f ->
        app.streamsetu.tv.ui.components.MenuAction(f.label + if (f.recordable) "" else "  (can't be recorded)", Icons.Filled.PlayArrow, enabled = f.recordable) { actions.recordFeed(f.channelId) }
    }, onClose = { feedMenu = false })
}

private fun nextOf(options: List<Int>, current: Int): Int = options[(options.indexOf(current).let { if (it < 0) -1 else it } + 1) % options.size]
