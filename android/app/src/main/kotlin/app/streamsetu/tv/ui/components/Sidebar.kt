package app.streamsetu.tv.ui.components

import app.streamsetu.tv.ui.theme.ui
import androidx.compose.foundation.border
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens

private fun iconOf(t: Tab): ImageVector = when (t) {
    Tab.HOME -> Icons.Filled.Home
    Tab.LIVE -> Icons.Filled.LiveTv
    Tab.MOVIES -> Icons.Filled.Movie
    Tab.SERIES -> Icons.Filled.VideoLibrary
    Tab.GUIDE -> Icons.Filled.CalendarMonth
    Tab.SEARCH -> Icons.Filled.Search
    Tab.LIBRARIES -> Icons.Filled.Layers
    Tab.SETTINGS -> Icons.Filled.Settings
}

/** What each entry is called in the sidebar (the same words as the page titles). */
private fun nameOf(t: Tab) = when (t) { Tab.LIBRARIES -> "Libraries"; Tab.GUIDE -> "TV Guide"; else -> t.title }

// The rail in three groups, with their names shown while it is open: what you watch, finding something, and managing the app.
private val Groups = listOf(
    "WATCH" to listOf(Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES),
    "DISCOVER" to listOf(Tab.SEARCH),
    "MANAGE" to listOf(Tab.LIBRARIES, Tab.SETTINGS),
)
private val AllTabs = Groups.flatMap { it.second }

private val Row get() = (56 * app.streamsetu.tv.ui.theme.UiScale.k).toInt()        // dp, the height of every entry
private val IconBox get() = (40 * app.streamsetu.tv.ui.theme.UiScale.k).toInt()    // dp, the square the icon is centred in

/**
 * The global navigation: a flat strip down the left edge. Collapsed it is icons only and takes its own width (the page starts to its right, so nothing is covered); with the remote on it
 * it widens over the page to show the names. The page you are on has a short bar beside its icon; the entry under the remote has a soft fill.
 */
@Composable
fun Sidebar(selected: Tab, onSelect: (Tab) -> Unit, entry: FocusRequester, modifier: Modifier = Modifier, expanded: Boolean = false, onFocusChange: (Boolean) -> Unit = {}, onReturn: () -> Unit = {}, livePlaying: Boolean = false) {
    var hadFocus by remember { mutableStateOf(false) }
    // The entry the remote is on. Right on Movies, Series or Live TV opens that screen's folders (the same as OK); on any other entry it returns to the page.
    var onTab by remember { mutableStateOf<Tab?>(null) }
    val scope = rememberCoroutineScope()
    var lossJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val reduced = LocalReducedMotion.current
    // The open rail is wide enough for the longest name at the text size in use (never more than 360 dp).
    val expandedWidth = minOf(360.dp, Tokens.sidebarExpanded * maxOf(1f, androidx.compose.ui.platform.LocalDensity.current.fontScale * 0.9f))
    val width by animateDpAsState(if (expanded) expandedWidth else Tokens.sidebarCompact, if (reduced) snap() else tween(Motion.SIDEBAR, easing = Motion.Standard), label = "sidebarWidth")
    // The fade is read only where it is drawn (graphicsLayer), so it redraws the labels each frame without recomposing the entries.
    val labelAlpha = animateFloatAsState(if (expanded) 1f else 0f, if (reduced) snap() else tween(Motion.SHORT), label = "sidebarLabels")
    // One stable focus requester per entry. Up and Down go from entry to entry and stop at the ends; Left never leaves. Compose's own search would otherwise carry the remote
    // out of the sidebar to whatever is beside it in the page.
    val requesters = remember { AllTabs.associateWith { FocusRequester() } }
    val order = AllTabs
    val fill = if (expanded) Tokens.card else Tokens.panel
    Column(
        modifier.fillMaxHeight().width(width)
            // Right leaves the rail and returns the remote to where it was in the page.
            .onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) { val t = onTab; if (t == Tab.MOVIES || t == Tab.SERIES || t == Tab.LIVE) onSelect(t) else onReturn(); true } else false }
            .background(fill)
            .drawBehind { drawLine(Tokens.line, androidx.compose.ui.geometry.Offset(size.width - 0.5f, 0f), androidx.compose.ui.geometry.Offset(size.width - 0.5f, size.height), 1.dp.toPx()) }
            // Moving between two entries can report "no focus" for an instant. Gaining focus is immediate; losing it only counts if it lasts, or the panel would hide itself mid-move.
            .onFocusChanged { st ->
                lossJob?.cancel()
                if (st.hasFocus) { if (!hadFocus) { hadFocus = true; onFocusChange(true) } }
                else if (hadFocus) lossJob = scope.launch { androidx.compose.runtime.withFrameNanos { }; androidx.compose.runtime.withFrameNanos { }; hadFocus = false; onFocusChange(false) }
            }
            .padding(vertical = Tokens.safeVertical, horizontal = 8.dp),
    ) {
        // The mark stays where it is as the strip widens; the name fades in beside it.
        Row(Modifier.heightIn(min = 40.dp).padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(28.dp).clip(RoundedCornerShape(7.dp)))
            Label("StreamSetu", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(start = 12.dp).graphicsLayer { alpha = labelAlpha.value })
        }
        // The entries sit in the middle of the strip; with larger text they can need more room than the screen has, so they scroll (the entry under the remote is kept in view).
        Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) {
            androidx.compose.runtime.CompositionLocalProvider(LocalInSidebar provides true) {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Groups.forEachIndexed { gi, (name, tabs) ->
                        if (gi > 0) Spacer(Modifier.height(10.dp))
                        // The group's name shows while the rail is open; closed, the groups are told apart by the space between them.
                        Label(name, Tokens.caption, Tokens.textTertiary, FontWeight.Bold, letterSpacing = 1.sp, modifier = Modifier.padding(start = 10.dp, bottom = 2.dp).graphicsLayer { alpha = labelAlpha.value })
                        tabs.forEach { SidebarEntry(it, selected, entry, labelAlpha, onSelect, requesters, order, livePlaying && it == Tab.LIVE, onFocusTab = { t -> onTab = t }) }
                    }
                }
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun SidebarEntry(t: Tab, selected: Tab, entry: FocusRequester, labelAlpha: State<Float>, onSelect: (Tab) -> Unit, requesters: Map<Tab, FocusRequester>, order: List<Tab>, playing: Boolean = false, onFocusTab: (Tab) -> Unit = {}) {
    val isSel = t == selected
    val i = order.indexOf(t)
    val up = order.getOrNull(i - 1)?.let { requesters.getValue(it) } ?: FocusRequester.Cancel
    val down = order.getOrNull(i + 1)?.let { requesters.getValue(it) } ?: FocusRequester.Cancel
    // With larger text an entry is taller (never less than 40 dp), and whichever one takes the remote is scrolled fully into view: the strip scrolls when its entries do not all fit.
    val rowMin = (Row * maxOf(1f, androidx.compose.ui.platform.LocalDensity.current.fontScale * 0.85f)).dp
    val bring = remember { androidx.compose.foundation.relocation.BringIntoViewRequester() }
    val scope = rememberCoroutineScope()
    Focusable({ onSelect(t) }, (if (isSel) Modifier.focusRequester(entry) else Modifier).focusRequester(requesters.getValue(t))
        .focusProperties { this.up = up; this.down = down; this.left = FocusRequester.Cancel }.testTag("sidebar-${t.name}").fillMaxWidth().heightIn(min = rowMin).bringIntoViewRequester(bring), scaleOnFocus = 1.0f, container = if (isSel) Color(0x1AFFFFFF) else Color.Transparent, focusedContainer = Color(0x40FFFFFF), shape = RoundedCornerShape(Tokens.radius), onFocus = { if (it) { onFocusTab(t); scope.launch { runCatching { bring.bringIntoView() } } } }, focusSound = app.streamsetu.tv.UISoundEvent.SIDEBAR_MOVE, selectSound = app.streamsetu.tv.UISoundEvent.NAVIGATE_FORWARD) { f ->
        Row(Modifier.heightIn(min = rowMin), verticalAlignment = Alignment.CenterVertically) {
            // The accent bar sits at the very left; the icon box is the same width in both states, so nothing shifts when the panel widens.
            Box(Modifier.padding(start = 2.dp).width(3.dp).height(20.dp).background(if (isSel) Tokens.accent else Color.Transparent, RoundedCornerShape(2.dp)))
            Box(Modifier.width(IconBox.dp - 3.dp), Alignment.Center) {
                Image(iconOf(t), nameOf(t), Modifier.size(25.ui), colorFilter = ColorFilter.tint(if (isSel || f) Color.White else Tokens.textSecondary))
            }
            Label(nameOf(t), Tokens.row, if (f || isSel) Color.White else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(start = 10.dp).graphicsLayer { alpha = labelAlpha.value })
            // A small dot beside Live TV while a channel is playing.
            if (playing) Box(Modifier.padding(start = 8.dp).size(7.dp).background(Tokens.accent, androidx.compose.foundation.shape.CircleShape))
        }
    }
}
