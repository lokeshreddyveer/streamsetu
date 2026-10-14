package app.streamsetu.tv.ui.components

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
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

private const val Row = 46        // dp, the height of every entry
private const val IconBox = 40    // dp, the square the icon is centred in: in the narrow strip it is centred in the strip

/**
 * The global navigation. Narrow: a strip of icons, each centred. Wide: the same icons stay exactly where they are, and the names appear to their right.
 * Floating (Home, Live TV, Movies, Series): a rounded panel with a margin, drawn over the page, with the mark on top.
 * Entries are 46 dp tall, with 4 dp between them; the page you are on has a thin accent bar and white text; the entry under the remote has a soft white fill.
 */
@Composable
fun Sidebar(selected: Tab, onSelect: (Tab) -> Unit, entry: FocusRequester, modifier: Modifier = Modifier, floating: Boolean = false, startExpanded: Boolean = false, onFocusChange: (Boolean) -> Unit = {}) {
    var hadFocus by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(startExpanded) }
    val reduced = LocalReducedMotion.current
    val width by animateDpAsState(if (expanded) Tokens.sidebarExpanded else Tokens.sidebarCompact, if (reduced) snap() else tween(Motion.SIDEBAR, easing = Motion.Standard), label = "sidebarWidth")
    val labelAlpha by animateFloatAsState(if (expanded) 1f else 0f, if (reduced) snap() else tween(Motion.SHORT), label = "sidebarLabels")
    val shape = if (floating) RoundedCornerShape(20.dp) else RoundedCornerShape(topEnd = 20.dp, bottomEnd = 20.dp)
    Column(
        (if (floating) modifier.padding(start = 16.dp, top = Tokens.safeVertical, bottom = Tokens.safeVertical).wrapContentHeight() else modifier.fillMaxHeight().padding(vertical = Tokens.safeVertical))
            .width(width).clip(shape)
            .background(Color(0xF2090909))
            .onFocusChanged { expanded = it.hasFocus || startExpanded; if (it.hasFocus != hadFocus) { hadFocus = it.hasFocus; onFocusChange(it.hasFocus) } }
            .padding(vertical = 10.dp, horizontal = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp, if (floating) Alignment.Top else Alignment.CenterVertically),
    ) {
        if (floating) {
            // The mark: the same spot whether the panel is narrow or wide.
            Row(Modifier.height(44.dp).padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.foundation.Image(painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)))
                Label("StreamSetu", Tokens.heading, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = 12.dp).graphicsLayer { alpha = labelAlpha })
            }
            Spacer(Modifier.height(4.dp))
        }
        Main.forEach { SidebarEntry(it, selected, entry, labelAlpha, onSelect) }
        Box(Modifier.padding(vertical = 4.dp, horizontal = 10.dp).fillMaxWidth().height(1.dp).background(Color(0x1FFFFFFF)))
        Other.forEach { SidebarEntry(it, selected, entry, labelAlpha, onSelect) }
    }
}

@Composable
private fun SidebarEntry(t: Tab, selected: Tab, entry: FocusRequester, labelAlpha: Float, onSelect: (Tab) -> Unit) {
    val isSel = t == selected
    Focusable({ onSelect(t) }, (if (isSel) Modifier.focusRequester(entry) else Modifier).fillMaxWidth().height(Row.dp), scaleOnFocus = 1.0f, container = Color.Transparent, focusedContainer = Color(0x26FFFFFF), shape = RoundedCornerShape(12.dp)) { f ->
        Row(Modifier.fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
            // The accent bar sits at the very left; the icon box is the same width in both states, so nothing shifts when the panel widens.
            Box(Modifier.padding(start = 2.dp).width(3.dp).height(20.dp).background(if (isSel) Tokens.accent else Color.Transparent, RoundedCornerShape(2.dp)))
            Box(Modifier.width(IconBox.dp - 3.dp), Alignment.Center) {
                Image(iconOf(t), nameOf(t), Modifier.size(22.dp), colorFilter = ColorFilter.tint(if (f || isSel) Color.White else Tokens.textSecondary))
            }
            Label(nameOf(t), Tokens.nav, if (f || isSel) Color.White else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(start = 10.dp).graphicsLayer { alpha = labelAlpha })
        }
    }
}
