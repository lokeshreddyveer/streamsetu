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
)

/** The page as the shell shows it. Refresh Guide uses the application's own guide refresh. */
@Composable
fun SportsScreen(vm: SportsViewModel, c: AppContainer, nav: Navigator) = SportsScreenHost(vm, nav) { c.ensureGuide(force = true) }

/** Wires the screen to the ViewModel, the Navigator (tab, Back, focus memory) and the application's existing routes. It does no work of its own. */
@Composable
fun SportsScreenHost(vm: SportsViewModel, nav: Navigator, refreshGuideNow: () -> Unit) {
    val state by vm.uiState.collectAsStateWithLifecycle()
    val current by rememberUpdatedState(state)
    val entry = LocalContentEntry.current ?: remember { FocusRequester() }
    LaunchedEffect(Unit) { vm.onEntered() }

    // Back closes the detail first; with none open the page does not take Back, so the sidebar opens.
    var previewFocused by remember { mutableStateOf(false) }
    var returnTick by remember { mutableStateOf(0) }
    // Back: from the embedded picture the remote goes back to the feed list (playback goes on); from the detail it closes the event, which ends what played from it.
    DisposableEffect(vm) {
        val hook: () -> Boolean = { if (current.detail != null) { if (previewFocused) returnTick++ else vm.closeDetail(); true } else false }
        nav.backHook = hook
        onDispose { if (nav.backHook === hook) nav.backHook = null }
    }

    val ids = remember(state.live, state.startingSoon, state.today, state.upcoming) { (state.live + state.startingSoon + state.today + state.upcoming).map { it.id } }
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
    // Closing the detail puts the remote back on the event it came from (or the nearest one), by frames and with no timers.
    var wasOpen by remember { mutableStateOf(false) }
    LaunchedEffect(detailOpen) {
        if (detailOpen) { wasOpen = true; return@LaunchedEffect }
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
            Hub(state, actions, entry, restore, restoreId, scroll)
        }
        state.detail?.let { SportsDetailPanel(it, actions, returnTick) }
    }
}

@Composable
private fun Hub(state: SportsHubUiState, actions: SportsActions, entry: FocusRequester, restore: FocusRequester, restoreId: String?, scroll: ScrollHolder) {
    val hasFilters = state.filters.isNotEmpty()
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical)) {
        SportsHeader(state.refreshing, entry.takeIf { !hasFilters }, actions.refresh)
        if (hasFilters) {
            SportsFilters(state.filters, state.selectedSport, entry, restore.takeIf { restoreId != null }, actions.select)
        }
        Spacer(Modifier.height(12.dp))
        val message = state.message
        when {
            state.loading && state.isEmpty -> SportsSkeleton()
            message != null -> SportsMessageView(message, actions)
            else -> SportsSections(state, actions, entry, restore, restoreId, scroll)
        }
    }
}

// ---- header and filters

@Composable
private fun SportsHeader(refreshing: Boolean, entry: FocusRequester?, onRefresh: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(bottom = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Label("Sports", Tokens.pageTitle, Tokens.text, FontWeight.Bold)
        if (refreshing) Label("Updating…", Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-refreshing"))
        Spacer(Modifier.weight(1f))
        TvButton("Refresh", onRefresh, (if (entry != null) Modifier.focusRequester(entry) else Modifier).testTag("sports-refresh"), icon = Icons.Filled.Refresh)
    }
}

@Composable
private fun SportsFilters(filters: List<SportsFilter>, selected: Sport?, entry: FocusRequester, restore: FocusRequester?, onSelect: (Sport?) -> Unit) {
    Row(Modifier.fillMaxWidth().testTag("sports-filters").onPreviewKeyEvent { e ->
        // Down goes to the event the remote was last on, when it is on screen; otherwise the normal search below decides.
        if (restore != null && e.type == KeyEventType.KeyDown && e.key == Key.DirectionDown) runCatching { restore.requestFocus() }.isSuccess else false
    }) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(filters, key = { it.sport?.name ?: "all" }) { f ->
                val isSelected = f.sport == selected
                SportsChip(f.label + (if (f.sport != null) "  ${f.count}" else ""), isSelected, if (isSelected) Modifier.focusRequester(entry) else Modifier, "sports-filter-${f.sport?.name ?: "ALL"}") { onSelect(f.sport) }
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
            SportsSectionRail(s, state.section(s), starts.getValue(s), actions, restore, restoreId, entry.takeIf { s == sections.first() })
        }
    }
}

/** One section on its own: moving the remote inside it recomposes this and nothing else. */
@Composable
private fun SportsSectionRail(section: SportsSection, cards: List<SportsEventCard>, firstIndex: Int, actions: SportsActions, restore: FocusRequester, restoreId: String?, upTo: FocusRequester?) {
    // Starts on the remembered event when it is in this section, so it is composed and can take the remote at once.
    val at = cards.indexOfFirst { it.id == restoreId }.coerceAtLeast(0)
    val row: LazyListState = rememberLazyListState(initialFirstVisibleItemIndex = at)
    Column(Modifier.testTag("sports-section-${section.name}")) {
        Label(section.title, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 8.dp))
        LazyRow(state = row, horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 6.dp)) {
            items(cards, key = { it.id }) { card ->
                val index = firstIndex + cards.indexOf(card)
                SportsEventCardView(card, (if (card.id == restoreId) Modifier.focusRequester(restore) else Modifier).then(if (upTo != null) Modifier.focusProperties { up = upTo } else Modifier), { actions.open(card.id) }) { focused -> if (focused) actions.remember(card.id, index) }
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
            }
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
    LaunchedEffect(d.card.id) { requestFocusOnFrames(8, { close.requestFocus() }, { closeFocused }) }
    // Back from the embedded picture: the remote returns to the feed that is playing, or to Watch Best Feed.
    LaunchedEffect(returnTick) {
        if (returnTick == 0) return@LaunchedEffect
        val target = d.feeds.firstOrNull { it.current }?.channelId?.let { rows[it] } ?: best
        runCatching { target.requestFocus() }
    }
    Row(Modifier.fillMaxSize().testTag("sports-detail")) {
        Box(Modifier.weight(1f).fillMaxHeight().background(androidx.compose.ui.graphics.Color(0x99000000)), Alignment.Center) {
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
            if (d.feeds.isNotEmpty()) {
                TvButton("Watch Best Feed", actions.watchBest, Modifier.focusRequester(best).testTag("sports-watch-best"), icon = Icons.Filled.PlayArrow, primary = true)
                d.bestLabel?.let { Label(it, Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-best-label")) }
            }
            if (play != null) SportsPlaybackNote(play, d, actions, rows)
            Label("Available feeds", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(d.feeds.size, key = { d.feeds[it].channelId.ifEmpty { it.toString() } }) { i ->
                    val f = d.feeds[i]
                    SportsFeedRowView(f, if (f.channelId.isNotEmpty()) Modifier.focusRequester(rows.getOrPut(f.channelId) { FocusRequester() }) else Modifier) { if (f.channelId.isNotEmpty()) actions.watchFeed(f.channelId) }
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
private fun SportsFeedRowView(f: SportsFeedRow, modifier: Modifier, onPlay: () -> Unit) {
    // OK plays this exact feed. Focus alone does nothing.
    Focusable(onPlay, modifier.fillMaxWidth().testTag("sports-feed"), shape = RoundedCornerShape(Tokens.radiusSmall), container = Tokens.card, scaleOnFocus = 1.0f, focusSound = null, selectSound = null) { _ ->
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
