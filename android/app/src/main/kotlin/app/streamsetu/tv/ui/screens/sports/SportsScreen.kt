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
    DisposableEffect(vm) {
        val hook: () -> Boolean = { if (current.detail != null) { vm.closeDetail(); true } else false }
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
        )
    }
    SportsHubContent(state, actions, entry, restoreId, ScrollHolder(vm), nav.contentRestoreAllowed)
}

/** Where the list was scrolled, kept by the ViewModel (the screen is not composed while another tab is open). */
class ScrollHolder(private val vm: SportsViewModel) {
    var index: Int get() = vm.scrollIndex; set(v) { vm.scrollIndex = v }
    var offset: Int get() = vm.scrollOffset; set(v) { vm.scrollOffset = v }
}

/** The whole Hub as a function of its state. No database, no classification, no formatting: everything is already in [state]. */
@Composable
fun SportsHubContent(state: SportsHubUiState, actions: SportsActions, entry: FocusRequester, restoreId: String?, scroll: ScrollHolder, parentFocusEnabled: Boolean = true) {
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
    Box(Modifier.fillMaxSize().testTag("sports-hub")) {
        // While the detail is open the Hub behind it cannot take the remote.
        CompositionLocalProvider(LocalFocusEnabled provides (parentFocusEnabled && !detailOpen)) {
            Hub(state, actions, entry, restore, restoreId, scroll)
        }
        state.detail?.let { SportsDetailPanel(it, actions.closeDetail) }
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
private fun SportsDetailPanel(d: SportsEventDetail, onClose: () -> Unit) {
    val close = remember { FocusRequester() }
    var closeFocused by remember { mutableStateOf(false) }
    LaunchedEffect(d.card.id) { requestFocusOnFrames(8, { close.requestFocus() }, { closeFocused }) }
    Row(Modifier.fillMaxSize().testTag("sports-detail")) {
        Spacer(Modifier.weight(1f).fillMaxHeight().background(androidx.compose.ui.graphics.Color(0x99000000)))
        Column(Modifier.width(560.ui).fillMaxHeight().background(Tokens.panel).padding(horizontal = 28.dp, vertical = Tokens.safeVertical).focusGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Label(d.card.title, Tokens.title, Tokens.text, FontWeight.Bold, maxLines = 3, modifier = Modifier.weight(1f))
                TvButton("Close", onClose, Modifier.focusRequester(close).testTag("sports-detail-close"), icon = Icons.Filled.Close, onFocus = { closeFocused = it })
            }
            Label(d.card.sportLabel + (d.card.competition?.let { " · $it" } ?: ""), Tokens.body, Tokens.textSecondary)
            Label(d.timeRange, Tokens.body, Tokens.text)
            Label(d.stateLabel, Tokens.body, if (d.card.live) Tokens.accent else Tokens.textSecondary, FontWeight.SemiBold)
            if (d.lowConfidence) Label("This listing was matched with lower confidence, so the details may be wrong.", Tokens.small, Tokens.warning, modifier = Modifier.testTag("sports-low-confidence"))
            Label("Channels", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(d.feeds.size, key = { it }) { i -> SportsFeedRowView(d.feeds[i]) }
            }
            Label("Playback from Sports will be added in the next phase. You can still find this channel in Live TV.", Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("sports-detail-note"))
        }
    }
}

@Composable
private fun SportsFeedRowView(f: SportsFeedRow) {
    // Informational: OK does nothing. The row can hold the remote only so a long list can be scrolled with the remote.
    Focusable({}, Modifier.fillMaxWidth().testTag("sports-feed"), shape = RoundedCornerShape(Tokens.radiusSmall), container = Tokens.card, scaleOnFocus = 1.0f, focusSound = null, selectSound = null) { _ ->
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Label(f.channelName + "  ·  " + f.sourceName, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1)
            val parts = ArrayList<String>()
            f.language?.let { parts.add("Language: ${it.text}" + (if (it.inferred) " (inferred)" else "")) }
            f.quality?.let { parts.add("Quality: ${it.text}" + (if (it.inferred) " (inferred)" else "")) }
            if (f.catchUp) parts.add("Catch-up available")
            if (parts.isNotEmpty()) Label(parts.joinToString("  ·  "), Tokens.small, Tokens.textSecondary, maxLines = 2)
        }
    }
}
