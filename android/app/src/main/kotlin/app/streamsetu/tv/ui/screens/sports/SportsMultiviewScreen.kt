package app.streamsetu.tv.ui.screens.sports

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.multiview.Dir
import app.streamsetu.tv.sports.multiview.FeedChoice
import app.streamsetu.tv.sports.multiview.MultiviewEntry
import app.streamsetu.tv.sports.multiview.MultiviewLayout
import app.streamsetu.tv.sports.multiview.MultiviewNav
import app.streamsetu.tv.sports.multiview.MultiviewNotice
import app.streamsetu.tv.sports.multiview.MultiviewState
import app.streamsetu.tv.sports.multiview.SelectionResult
import app.streamsetu.tv.sports.multiview.SelectionState
import app.streamsetu.tv.sports.multiview.TileStatus
import app.streamsetu.tv.sports.multiview.TileUi
import app.streamsetu.tv.ui.components.ContextMenu
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.MenuAction
import app.streamsetu.tv.ui.components.Spinner
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.components.requestFocusOnFrames
import app.streamsetu.tv.ui.screens.MultiviewUnsupported
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/** What Back does, in order: a menu first, then a replacement being chosen, then the tiles (back to the builder), then the builder (back to Sports). Never anything else. */
enum class BackStep { CLOSE_MENU, CANCEL_REPLACE, TO_BUILDER, LEAVE }

fun multiviewBack(menuOpen: Boolean, replacing: Boolean, watching: Boolean): BackStep = when { menuOpen -> BackStep.CLOSE_MENU; replacing -> BackStep.CANCEL_REPLACE; watching -> BackStep.TO_BUILDER; else -> BackStep.LEAVE }

/** One event the builder offers: what the card says. */
@androidx.compose.runtime.Immutable
data class MultiviewCandidate(val eventId: String, val title: String, val sportLabel: String, val feedCount: Int, val chosen: Boolean, val followed: Boolean = false)

/** What the builder can do. Each is the person pressing OK (or the menu key); nothing here runs from focus. */
class BuilderActions(
    val add: (eventId: String) -> Unit, val chooseFeed: (eventId: String) -> Unit, val openEntry: (index: Int) -> Unit,
    val start: () -> Unit, val clear: () -> Unit, val close: () -> Unit,
)

/** What a tile can do. */
class TileActions(
    val open: (TileUi) -> Unit, val retry: (TileUi) -> Unit, val replace: (TileUi) -> Unit, val remove: (TileUi) -> Unit,
    val useTwo: () -> Unit, val keepOne: () -> Unit, val toBuilder: () -> Unit,
)

private sealed interface Menu {
    data class Entry(val index: Int) : Menu
    data class Tile(val tile: TileUi) : Menu
    data class Feeds(val eventId: String, val forTile: TileUi?, val entryIndex: Int?, val choices: List<FeedChoice>) : Menu
    data class Events(val replacing: TileUi?, val entryIndex: Int?) : Menu
}

/**
 * The Sports Multi-View: first the builder (the list of chosen feeds and the live events to add), then the tiles. The builder only edits a list; the tiles are started by Start Multiview, one
 * after another, by the session. Back closes a menu, then leaves the tiles for the builder, then the builder for Sports.
 */
@Composable
fun SportsMultiviewScreen(c: AppContainer, onClose: () -> Unit, onFullScreen: (Channel) -> Unit) {
    val ctl = c.sportsMultiview
    val sel by ctl.selection.state.collectAsStateWithLifecycle()
    val mv by ctl.session.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf<Menu?>(null) }
    var replacingEntry by remember { mutableStateOf<Int?>(null) }
    val now = System.currentTimeMillis()
    val live = remember(sel, mv.active) { ctl.selection.liveEvents(now) }
    val followSet by c.sportsFollows.follows.collectAsStateWithLifecycle(app.streamsetu.tv.sports.personal.FollowSet.NONE)
    val followedIds = remember(followSet, live) { app.streamsetu.tv.sports.discovery.MultiviewHints.followedIds(followSet, ctl.selection.loadedEvents(), live) }

    // The list keeps only channels that still have a tile (a tile removed by hand, or because it is no longer allowed).
    LaunchedEffect(mv.tiles.map { it.channelId }) { if (mv.active) ctl.selection.keepOnly(mv.tiles.map { it.channelId }.toSet()) }
    // The tiles of an old situation do not outlive it: a change to who may see what is checked tile by tile.
    LaunchedEffect(Unit) { if (!mv.active) ctl.selection.revalidate() }
    // Leaving releases every player.
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { ctl.session.stopAll() } }
    BackHandler(enabled = true) {
        when (multiviewBack(menu != null, replacingEntry != null, mv.active)) {
            BackStep.CLOSE_MENU -> menu = null
            BackStep.CANCEL_REPLACE -> replacingEntry = null
            BackStep.TO_BUILDER -> ctl.session.stopAll()
            BackStep.LEAVE -> onClose()
        }
    }

    suspend fun openFeeds(eventId: String, tile: TileUi?, entryIndex: Int?) { menu = Menu.Feeds(eventId, tile, entryIndex, ctl.selection.feedChoices(eventId)) }
    fun entryIndexOf(t: TileUi) = ctl.selection.state.value.entries.indexOfFirst { it.channelId == t.channelId }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (mv.active) {
            MultiviewTiles(mv, { id, ctx -> ctl.session.viewFor(id, ctx) }, TileActions(
                open = { menu = Menu.Tile(it) }, retry = { ctl.session.retry(it.id) }, replace = { menu = Menu.Events(it, entryIndexOf(it).takeIf { i -> i >= 0 }) }, remove = { ctl.session.remove(it.id) },
                useTwo = { ctl.session.useAtMost(2) }, keepOne = { ctl.session.useAtMost(1) }, toBuilder = { ctl.session.stopAll() },
            ))
        } else if (ctl.capability.usableLimit() < 2) {
            MultiviewUnsupported(onClose, null)
        } else {
            val candidates = live.map { e -> MultiviewCandidate(e.id, e.title, e.sport.title, e.feeds.size, sel.entries.any { it.eventId == e.id }, followed = e.id in followedIds) }
            MultiviewBuilder(sel, candidates, replacingEntry, BuilderActions(
                add = { id -> scope.launch { val r = replacingEntry; if (r != null) { ctl.selection.replace(r, id); replacingEntry = null } else ctl.selection.add(id) } },
                chooseFeed = { id -> scope.launch { openFeeds(id, null, replacingEntry) } },
                openEntry = { menu = Menu.Entry(it) },
                start = { if (sel.canStart) ctl.session.start(sel.entries) }, clear = { ctl.selection.clear() }, close = onClose,
            ))
        }

        menu?.let { m ->
            when (m) {
                is Menu.Entry -> sel.entries.getOrNull(m.index)?.let { e ->
                    ContextMenu(e.eventTitle, e.feedLabel, listOf(
                        MenuAction("Change feed", Icons.Filled.SwapHoriz) { scope.launch { openFeeds(e.eventId, null, m.index) } },
                        MenuAction("Replace with another event", Icons.Filled.Add) { replacingEntry = m.index },
                        MenuAction("Move earlier", Icons.Filled.Add, enabled = m.index > 0) { ctl.selection.move(m.index, -1) },
                        MenuAction("Move later", Icons.Filled.Add, enabled = m.index < sel.entries.lastIndex) { ctl.selection.move(m.index, 1) },
                        MenuAction("Remove", Icons.Filled.Close, danger = true) { ctl.selection.remove(m.index) },
                    ), onClose = { menu = null })
                }
                is Menu.Feeds -> ContextMenu("Choose a feed", null, m.choices.map { f ->
                    MenuAction(f.label + if (f.unsupported) " (may not show here)" else "", Icons.Filled.PlayArrow) {
                        scope.launch {
                            when {
                                m.forTile != null && m.entryIndex != null -> if (ctl.selection.changeFeed(m.entryIndex, f.channelId) is SelectionResult.Done) ctl.selection.state.value.entries.getOrNull(m.entryIndex)?.let { ctl.session.replace(m.forTile.id, it) }
                                m.entryIndex != null -> ctl.selection.changeFeed(m.entryIndex, f.channelId)
                                else -> ctl.selection.add(m.eventId, f.channelId, allowSameEvent = false)
                            }
                        }
                    }
                }.ifEmpty { listOf(MenuAction("No feed is available", Icons.Filled.Close) {}) }, onClose = { menu = null })
                is Menu.Events -> ContextMenu("Replace with", null, live.filter { e -> sel.entries.none { it.eventId == e.id } }.take(12).map { e ->
                    MenuAction(e.title, Icons.Filled.PlayArrow) {
                        scope.launch {
                            val idx = m.entryIndex
                            if (idx != null && ctl.selection.replace(idx, e.id) is SelectionResult.Done) ctl.selection.state.value.entries.getOrNull(idx)?.let { en -> m.replacing?.let { t -> ctl.session.replace(t.id, en) } }
                        }
                    }
                }.ifEmpty { listOf(MenuAction("No other live event", Icons.Filled.Close) {}) }, onClose = { menu = null })
                is Menu.Tile -> {
                    val t = m.tile
                    val slot = mv.tiles.indexOfFirst { it.id == t.id }
                    val acts = ArrayList<MenuAction>()
                    when (t.status) {
                        TileStatus.PLAYING -> {
                            if (!t.audio) acts += MenuAction("Listen here", Icons.Filled.VolumeUp) { ctl.session.listenHere(t.id) }
                            if (slot > 0) acts += MenuAction("Make primary", Icons.Filled.Fullscreen) { ctl.session.makePrimary(t.id) }
                            acts += MenuAction("Full screen", Icons.Filled.Fullscreen) { scope.launch { c.catalog.channel(t.channelId)?.let { ch -> ctl.session.stopAll(); onFullScreen(ch) } } }
                        }
                        TileStatus.FAILED -> acts += MenuAction("Retry", Icons.Filled.Refresh) { ctl.session.retry(t.id) }
                        TileStatus.NO_DECODER -> acts += MenuAction("Use two views", Icons.Filled.Fullscreen) { ctl.session.useAtMost(2) }
                        else -> if (slot > 0) acts += MenuAction("Make primary", Icons.Filled.Fullscreen) { ctl.session.makePrimary(t.id) }
                    }
                    if (t.status != TileStatus.NO_DECODER && t.eventId != null) acts += MenuAction("Change feed", Icons.Filled.SwapHoriz) { scope.launch { openFeeds(t.eventId, t, entryIndexOf(t)) } }
                    acts += MenuAction("Replace event", Icons.Filled.Add) { menu = Menu.Events(t, entryIndexOf(t).takeIf { it >= 0 }) }
                    acts += MenuAction("Remove", Icons.Filled.Close, danger = true) { ctl.session.remove(t.id) }
                    ContextMenu(t.eventTitle ?: t.feedLabel, t.feedLabel, acts, onClose = { menu = null })
                }
            }
        }
    }
}

// ---- the builder

@Composable
fun MultiviewBuilder(sel: SelectionState, candidates: List<MultiviewCandidate>, replacing: Int?, actions: BuilderActions) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { requestFocusOnFrames(8, { first.requestFocus() }, { false }) }
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical).testTag("mv-builder"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("BUILD MULTIVIEW", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.weight(1f))
            Label("${sel.entries.size} of ${sel.limit} views", Tokens.small, Tokens.textSecondary)
            TvButton("Close", actions.close, Modifier.testTag("mv-close"), icon = Icons.Filled.Close)
        }
        Label("Selected", Tokens.heading, Tokens.text, FontWeight.SemiBold)
        if (sel.entries.isEmpty()) Label("Choose two or more live events below.", Tokens.body, Tokens.textSecondary, modifier = Modifier.testTag("mv-empty"))
        sel.entries.forEachIndexed { i, e ->
            Focusable({ actions.openEntry(i) }, Modifier.fillMaxWidth().testTag("mv-entry-$i"), shape = RoundedCornerShape(Tokens.radiusSmall), scaleOnFocus = 1.0f) {
                Label("${i + 1}. ${e.eventTitle} · ${e.feedLabel}", Tokens.row, Tokens.text, maxLines = 1, modifier = Modifier.padding(12.dp))
            }
        }
        if (replacing != null) Label("Choose the event that replaces view ${replacing + 1}.", Tokens.small, Tokens.accent, modifier = Modifier.testTag("mv-replacing"))
        Label("Available Live Events", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
        if (candidates.isEmpty()) Label("No live events right now.", Tokens.body, Tokens.textSecondary)
        else LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(candidates, key = { it.eventId }) { cd -> CandidateCard(cd, "mv-event-${cd.eventId}", if (cd === candidates.first()) Modifier.focusRequester(first) else Modifier, actions) }
        }
        // What the profile follows and is live now: shown, never added by itself.
        val mine = candidates.filter { it.followed }
        if (mine.isNotEmpty()) {
            Label("My Sports · live now", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp).testTag("mv-mine-title"))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) { items(mine, key = { "m-" + it.eventId }) { cd -> CandidateCard(cd, "mv-mine-${cd.eventId}", Modifier, actions) } }
        }
        sel.message?.let { Label(it, Tokens.small, Tokens.warning, modifier = Modifier.testTag("mv-message")) }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 6.dp)) {
            TvButton("Start Multiview", actions.start, Modifier.testTag("mv-start"), icon = Icons.Filled.PlayArrow, primary = sel.canStart)
            if (sel.entries.isNotEmpty()) TvButton("Clear", actions.clear, Modifier.testTag("mv-clear"))
        }
        if (!sel.canStart) Label("Two feeds are the least a Multiview needs.", Tokens.small, Tokens.textSecondary)
    }
}

@Composable
private fun CandidateCard(cd: MultiviewCandidate, tag: String, modifier: Modifier, actions: BuilderActions) {
    Focusable({ actions.add(cd.eventId) }, Modifier.width(260.dp).testTag(tag).then(modifier), shape = RoundedCornerShape(Tokens.radiusSmall), onLongClick = { actions.chooseFeed(cd.eventId) }, scaleOnFocus = 1.0f) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Label(cd.title, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 2)
            Label(cd.sportLabel + "  ·  " + cd.feedCount + if (cd.feedCount == 1) " feed" else " feeds", Tokens.small, Tokens.textSecondary, maxLines = 1)
            if (cd.chosen) Label("Added", Tokens.small, Tokens.accent, FontWeight.SemiBold)
        }
    }
}

// ---- the tiles

@Composable
fun MultiviewTiles(mv: MultiviewState, viewFor: (Long, android.content.Context) -> android.view.View?, actions: TileActions, portrait: Boolean = false) {
    val rects = remember(mv.tiles.size, portrait) { MultiviewLayout.rects(mv.tiles.size, portrait) }
    val requesters = remember { HashMap<Long, FocusRequester>() }
    val buttonRequesters = remember { HashMap<Long, List<FocusRequester>>() }
    var focusedId by remember { mutableStateOf<Long?>(null) }
    var focusedButton by remember { mutableStateOf(-1) }
    val first = mv.tiles.firstOrNull()
    LaunchedEffect(first?.id) { first?.let { f -> requestFocusOnFrames(8, { entryOf(f, requesters, buttonRequesters).requestFocus() }, { focusedId != null }) } }
    // The picture of a tile that failed or was removed is dropped from the maps with it.
    LaunchedEffect(mv.tiles.map { it.id }) { val ids = mv.tiles.map { it.id }.toSet(); requesters.keys.retainAll(ids); buttonRequesters.keys.retainAll(ids) }

    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical).testTag("mv-tiles").onPreviewKeyEvent { e ->
        // Direction keys move between tiles by position. At an edge they do nothing: leaving needs Back.
        val dir = when (e.key) { Key.DirectionUp -> Dir.UP; Key.DirectionDown -> Dir.DOWN; Key.DirectionLeft -> Dir.LEFT; Key.DirectionRight -> Dir.RIGHT; else -> return@onPreviewKeyEvent false }
        if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent true
        val slot = mv.tiles.indexOfFirst { it.id == focusedId }
        if (slot < 0) return@onPreviewKeyEvent false
        val t = mv.tiles[slot]
        // Inside a failed tile Left and Right move between its three choices until the last one.
        if (t.status == TileStatus.FAILED && (dir == Dir.LEFT || dir == Dir.RIGHT)) {
            val b = focusedButton
            if ((dir == Dir.RIGHT && b in 0..1) || (dir == Dir.LEFT && b in 1..2)) return@onPreviewKeyEvent false
        }
        val target = MultiviewNav.move(rects, slot, dir)
        if (target != null) mv.tiles.getOrNull(target)?.let { runCatching { entryOf(it, requesters, buttonRequesters).requestFocus() } }
        true
    }) {
        val widthPx = with(LocalDensity.current) { maxWidth.toPx() }; val heightPx = with(LocalDensity.current) { maxHeight.toPx() }
        mv.tiles.forEachIndexed { slot, t ->
            val r = rects[slot]
            key(t.id) {
                val d = LocalDensity.current
                Box(Modifier.offset { androidx.compose.ui.unit.IntOffset((r.x * widthPx).toInt() + 3, (r.y * heightPx).toInt() + 3) }
                    .size(with(d) { (r.w * widthPx).toInt().toDp() - 6.dp }, with(d) { (r.h * heightPx).toInt().toDp() - 6.dp })) {
                    TileView(t, viewFor, actions, requesters.getOrPut(t.id) { FocusRequester() }, buttonRequesters.getOrPut(t.id) { List(3) { FocusRequester() } }, { focusedId = t.id }, { focusedButton = it })
                }
            }
        }
        // Only one view left, or none can start: the screen says so and offers the way on. It never exits by itself.
        mv.notice?.let { NoticeBar(it, actions, Modifier.align(Alignment.BottomCenter)) }
    }
}

private fun entryOf(t: TileUi, req: Map<Long, FocusRequester>, buttons: Map<Long, List<FocusRequester>>): FocusRequester =
    if (t.status == TileStatus.FAILED || t.status == TileStatus.NO_DECODER) buttons[t.id]!!.first() else req[t.id]!!

@Composable
private fun TileView(t: TileUi, viewFor: (Long, android.content.Context) -> android.view.View?, actions: TileActions, req: FocusRequester, buttons: List<FocusRequester>, onFocused: () -> Unit, onButton: (Int) -> Unit) {
    val ctx = LocalContext.current
    val broken = t.status == TileStatus.FAILED || t.status == TileStatus.NO_DECODER
    Box(Modifier.fillMaxSize().background(Color.Black, RoundedCornerShape(8.dp)).onFocusChanged { if (it.hasFocus) onFocused() }.testTag("mv-tile-${t.channelId}")) {
        // The picture stays mounted: its view is the player's own, moved with the tile and never rebuilt.
        AndroidView(factory = { c -> android.widget.FrameLayout(c).also { f -> viewFor(t.id, c)?.let { v -> (v.parent as? android.view.ViewGroup)?.removeView(v); f.addView(v) } } }, modifier = Modifier.fillMaxSize())
        Focusable({ actions.open(t) }, Modifier.fillMaxSize().testTag("mv-focus-${t.channelId}").then(if (broken) Modifier else Modifier.focusRequester(req)), shape = RoundedCornerShape(8.dp), container = Color.Transparent, focusedContainer = Color.Transparent, scaleOnFocus = 1.0f, ringWidth = 3.dp, focusSound = null) {
            Row(Modifier.align(Alignment.TopStart).padding(8.dp).background(Tokens.pick(Color(0x99000000), Tokens.chipScrim), RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                androidx.compose.foundation.Image(if (t.audio) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, if (t.audio) "Sound" else "Muted", Modifier.size(16.dp).testTag(if (t.audio) "mv-audio" else "mv-muted"), colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(if (t.audio) Tokens.accent else Tokens.textSecondary))
                Label(t.eventTitle ?: t.feedLabel, Tokens.small, Tokens.text, FontWeight.Medium, maxLines = 1)
            }
            if (t.status == TileStatus.STARTING || t.status == TileStatus.QUEUED) Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { Spinner(); Label("Loading…", Tokens.small, Tokens.textSecondary) }
            if (t.message != null && !broken) Label(t.message, Tokens.small, Tokens.textSecondary, modifier = Modifier.align(Alignment.BottomStart).padding(8.dp).testTag("mv-tile-message"))
        }
        if (broken) Column(Modifier.align(Alignment.Center).padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label(t.message.orEmpty(), Tokens.body, Tokens.text, FontWeight.SemiBold, maxLines = 3)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (t.status == TileStatus.FAILED) TvButton("Try Again", { actions.retry(t) }, Modifier.focusRequester(buttons[0]).testTag("mv-retry"), onFocus = { if (it) onButton(0) })
                else TvButton("Use Two Views", { actions.useTwo() }, Modifier.focusRequester(buttons[0]).testTag("mv-use-two"), onFocus = { if (it) onButton(0) })
                TvButton("Replace", { actions.replace(t) }, Modifier.focusRequester(buttons[1]).testTag("mv-replace"), onFocus = { if (it) onButton(1) })
                TvButton("Remove", { actions.remove(t) }, Modifier.focusRequester(buttons[2]).testTag("mv-remove"), onFocus = { if (it) onButton(2) })
            }
        }
    }
}

@Composable
private fun NoticeBar(n: MultiviewNotice, actions: TileActions, modifier: Modifier) {
    Column(modifier.fillMaxWidth().background(Color(0xE6101418), RoundedCornerShape(10.dp)).padding(12.dp).testTag("mv-notice"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (n) {
            MultiviewNotice.ONE_LEFT -> {
                Label("Only one view is left.", Tokens.body, Tokens.text, FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { TvButton("Continue with one", actions.keepOne, Modifier.testTag("mv-continue-one")); TvButton("Return to Sports", actions.toBuilder, Modifier.testTag("mv-to-builder")) }
            }
            MultiviewNotice.NO_DECODER -> Label("This device cannot play another video at the same time.", Tokens.body, Tokens.text, FontWeight.SemiBold)
            MultiviewNotice.NOT_ENOUGH -> Label("A Multiview needs two feeds.", Tokens.body, Tokens.text, FontWeight.SemiBold)
        }
    }
}
