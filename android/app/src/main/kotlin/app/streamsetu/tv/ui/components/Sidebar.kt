package app.streamsetu.tv.ui.components

import androidx.compose.foundation.border
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
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

private val Main = listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.GUIDE)
private val Other = listOf(Tab.SEARCH, Tab.LIBRARIES, Tab.SETTINGS)

private const val Row = 40        // dp, the height of every entry
private const val IconBox = 34    // dp, the square the icon is centred in: in the narrow strip it is centred in the strip

/**
 * The global navigation: a flat strip down the left edge. Collapsed it is icons only and takes its own width (the page starts to its right, so nothing is covered); with the remote on it
 * it widens over the page to show the names. The page you are on has a short bar beside its icon; the entry under the remote has a soft fill.
 */
@Composable
fun Sidebar(selected: Tab, onSelect: (Tab) -> Unit, entry: FocusRequester, modifier: Modifier = Modifier, expanded: Boolean = false, onFocusChange: (Boolean) -> Unit = {}, onReturn: () -> Unit = {}) {
    var hadFocus by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var lossJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val reduced = LocalReducedMotion.current
    val width by animateDpAsState(if (expanded) Tokens.sidebarExpanded else Tokens.sidebarCompact, if (reduced) snap() else tween(Motion.SIDEBAR, easing = Motion.Standard), label = "sidebarWidth")
    // The fade is read only where it is drawn (graphicsLayer), so it redraws the labels each frame without recomposing the entries.
    val labelAlpha = animateFloatAsState(if (expanded) 1f else 0f, if (reduced) snap() else tween(Motion.SHORT), label = "sidebarLabels")
    // One stable focus requester per entry. Up and Down go from entry to entry and stop at the ends; Left never leaves. Compose's own search would otherwise carry the remote
    // out of the sidebar to whatever is beside it in the page.
    val requesters = remember { (Main + Other).associateWith { FocusRequester() } }
    val order = remember { Main + Other }
    val fill = if (expanded) Tokens.card else Tokens.panel
    Column(
        modifier.fillMaxHeight().width(width)
            // Right leaves the rail and returns the remote to where it was in the page.
            .onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) { onReturn(); true } else false }
            .background(fill)
            .drawBehind { drawLine(Tokens.line, androidx.compose.ui.geometry.Offset(size.width - 0.5f, 0f), androidx.compose.ui.geometry.Offset(size.width - 0.5f, size.height), 1.dp.toPx()) }
            // Moving between two entries can report "no focus" for an instant. Gaining focus is immediate; losing it only counts if it lasts, or the panel would hide itself mid-move.
            .onFocusChanged { st ->
                lossJob?.cancel()
                if (st.hasFocus) { if (!hadFocus) { hadFocus = true; onFocusChange(true) } }
                else if (hadFocus) lossJob = scope.launch { delay(140); hadFocus = false; onFocusChange(false) }
            }
            .padding(vertical = Tokens.safeVertical, horizontal = 8.dp),
    ) {
        // The mark stays where it is as the strip widens; the name fades in beside it.
        Row(Modifier.height(40.dp).padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(28.dp).clip(RoundedCornerShape(7.dp)))
            Label("StreamSetu", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(start = 12.dp).graphicsLayer { alpha = labelAlpha.value })
        }
        Spacer(Modifier.weight(1f))
        androidx.compose.runtime.CompositionLocalProvider(LocalInSidebar provides true) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Main.forEach { SidebarEntry(it, selected, entry, labelAlpha, onSelect, requesters, order) }
                Spacer(Modifier.height(10.dp))
                Other.forEach { SidebarEntry(it, selected, entry, labelAlpha, onSelect, requesters, order) }
            }
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun SidebarEntry(t: Tab, selected: Tab, entry: FocusRequester, labelAlpha: State<Float>, onSelect: (Tab) -> Unit, requesters: Map<Tab, FocusRequester>, order: List<Tab>) {
    val isSel = t == selected
    val i = order.indexOf(t)
    val up = order.getOrNull(i - 1)?.let { requesters.getValue(it) } ?: FocusRequester.Cancel
    val down = order.getOrNull(i + 1)?.let { requesters.getValue(it) } ?: FocusRequester.Cancel
    Focusable({ onSelect(t) }, (if (isSel) Modifier.focusRequester(entry) else Modifier).focusRequester(requesters.getValue(t))
        .focusProperties { this.up = up; this.down = down; this.left = FocusRequester.Cancel }.testTag("sidebar-${t.name}").fillMaxWidth().height(Row.dp), scaleOnFocus = 1.0f, container = Color.Transparent, focusedContainer = Color(0x26FFFFFF), shape = RoundedCornerShape(Tokens.radius), focusSound = app.streamsetu.tv.UISoundEvent.SIDEBAR_MOVE, selectSound = app.streamsetu.tv.UISoundEvent.NAVIGATE_FORWARD) { f ->
        Row(Modifier.fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
            // The accent bar sits at the very left; the icon box is the same width in both states, so nothing shifts when the panel widens.
            Box(Modifier.padding(start = 2.dp).width(3.dp).height(20.dp).background(if (isSel) Tokens.accent else Color.Transparent, RoundedCornerShape(2.dp)))
            Box(Modifier.width(IconBox.dp - 3.dp), Alignment.Center) {
                Image(iconOf(t), nameOf(t), Modifier.size(19.dp), colorFilter = ColorFilter.tint(if (isSel || f) Color.White else Tokens.textSecondary))
            }
            Label(nameOf(t), Tokens.row, if (f || isSel) Color.White else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(start = 10.dp).graphicsLayer { alpha = labelAlpha.value })
        }
    }
}
