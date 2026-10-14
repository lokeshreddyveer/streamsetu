package app.streamsetu.tv.ui.components

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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.core.ui.motion.LocalReducedMotion
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

/**
 * The global navigation: a narrow strip of icons that widens to show labels while the remote is on it.
 * The width animates as one value, and labels fade with it; the icons never move.
 */
@Composable
fun Sidebar(selected: Tab, onSelect: (Tab) -> Unit, entry: FocusRequester, modifier: Modifier = Modifier, floating: Boolean = false, startExpanded: Boolean = false) {
    var expanded by remember { mutableStateOf(startExpanded) }
    val reduced = LocalReducedMotion.current
    val width by androidx.compose.animation.core.animateDpAsState(if (expanded) Tokens.sidebarExpanded else Tokens.sidebarCompact, if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(Motion.SIDEBAR, easing = Motion.Standard), label = "sidebarWidth")
    val labelAlpha by androidx.compose.animation.core.animateFloatAsState(if (expanded) 1f else 0f, if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(Motion.SHORT), label = "sidebarLabels")
    // Floating: a rounded panel with a margin around it, hovering over the page. Docked: a full-height strip.
    val shape = if (floating) RoundedCornerShape(22.dp) else RoundedCornerShape(0.dp)
    Column(
        (if (floating) modifier.padding(start = 14.dp, top = Tokens.safeVertical, bottom = Tokens.safeVertical).wrapContentHeight() else modifier.fillMaxHeight()).width(width).clip(shape)
            .background(Brush.horizontalGradient(listOf(Tokens.panel.copy(alpha = if (floating) 0.94f else 1f), Tokens.panel.copy(alpha = if (floating) 0.9f else if (expanded) 0.96f else 0.7f))))
            .onFocusChanged { expanded = it.hasFocus || startExpanded }
            .padding(vertical = if (floating) 14.dp else Tokens.safeVertical, horizontal = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Tab.entries.forEach { t ->
            val isSel = t == selected
            Focusable({ onSelect(t) }, (if (isSel) Modifier.focusRequester(entry) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f, container = Color.Transparent, focusedContainer = Tokens.focusedSurface, shape = RoundedCornerShape(10.dp)) { f ->
                Row(Modifier.padding(horizontal = 12.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Image(iconOf(t), t.title, Modifier.size(24.dp), colorFilter = ColorFilter.tint(if (f || isSel) Tokens.accent else Tokens.textSecondary))
                    Label(t.title, Tokens.heading, if (isSel) Tokens.text else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.graphicsLayer { alpha = labelAlpha })
                }
            }
        }
    }
}
