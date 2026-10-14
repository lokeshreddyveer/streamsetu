package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.Category
import app.streamsetu.tv.nav.Pin
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens

/** The sidebar row that DOWN from the top bar lands on (the selected shortcut). Provided once at the root. */
val LocalSidebarEntry = androidx.compose.runtime.compositionLocalOf<FocusRequester?> { null }

/** The Mac's top bar: the brand on the left, the five sections in the middle, search and settings on the right. */
@Composable
fun TopBar(selected: Tab, first: FocusRequester, onHasFocus: (Boolean) -> Unit = {}, canAutoSelect: () -> Boolean = { true }, onSelect: (Tab) -> Unit) {
    val entry = LocalSidebarEntry.current
    fun Modifier.down(tab: Tab): Modifier = if (entry != null && tab != Tab.SEARCH) this.focusProperties { down = entry } else this
    Row(
        Modifier.fillMaxWidth().height(Tokens.headerHeight).background(Tokens.panel).padding(horizontal = Tokens.screenPadding).onFocusChanged { onHasFocus(it.hasFocus) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Label("StreamSetu", Tokens.heading, Tokens.accent, FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.GUIDE).forEach { tab ->
                TopTab(tab.title, tab == selected, { onSelect(tab) }, (if (tab == selected) Modifier.focusRequester(first) else Modifier).down(tab), canAutoSelect)
            }
        }
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTab(Icons.Filled.Search, "Search", selected == Tab.SEARCH, if (selected == Tab.SEARCH) Modifier.focusRequester(first) else Modifier, canAutoSelect) { onSelect(Tab.SEARCH) }
            IconTab(Icons.Filled.Settings, "Settings", selected == Tab.SETTINGS, (if (selected == Tab.SETTINGS) Modifier.focusRequester(first) else Modifier).down(Tab.SETTINGS), canAutoSelect) { onSelect(Tab.SETTINGS) }
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Tokens.line))
}

@Composable
private fun TopTab(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, canAutoSelect: () -> Boolean = { true }) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent,
        focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.04f) { focused ->
        // Moving along the bar shows each section as the focus rests on it; no need to press OK.
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); if (canAutoSelect()) onClick() } }
        androidx.compose.foundation.text.BasicText(title, Modifier.padding(horizontal = 11.dp, vertical = 5.dp),
            style = androidx.compose.ui.text.TextStyle(color = if (selected || focused) Tokens.accent else Tokens.textSecondary, fontSize = Tokens.row, fontWeight = FontWeight.SemiBold), maxLines = 1, softWrap = false)
    }
}

@Composable
private fun IconTab(icon: ImageVector, label: String, selected: Boolean, modifier: Modifier = Modifier, canAutoSelect: () -> Boolean = { true }, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent, focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.08f) { focused ->
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); if (canAutoSelect()) onClick() } }
        Image(icon, label, Modifier.padding(6.dp).size(18.dp), colorFilter = ColorFilter.tint(if (selected || focused) Tokens.accent else Tokens.textSecondary))
    }
}

private fun Pin.icon(): ImageVector = when (this) {
    Pin.DISCOVER, Pin.FEATURED -> Icons.Filled.AutoAwesome
    Pin.CONTINUE -> Icons.Filled.PlayArrow
    Pin.RECENT, Pin.RECENTLY_ADDED -> Icons.Filled.History
    Pin.HISTORY, Pin.ALL_CHANNELS -> Icons.Filled.FormatListBulleted
    Pin.FAVOURITES -> Icons.Filled.FavoriteBorder
    Pin.WATCH_LATER -> Icons.Filled.BookmarkBorder
    Pin.ALL_MOVIES, Pin.LIBRARY -> Icons.Filled.GridView
}

/**
 * The Mac's contextual sidebar: fixed shortcuts on top, then a "FOLDERS" list (the provider's categories). Only the folders scroll.
 * The selected entry shows in the accent colour on a faint white wash; the sidebar sits on the panel colour with a hairline on its right.
 */
@Composable
fun ContextSidebar(pins: List<Pin>, folders: List<Category>, selectedId: String, onSelect: (String) -> Unit, pinId: (Pin) -> String = { it.id }) {
    val entry = LocalSidebarEntry.current
    // The sidebar tucks away to a slim icon strip while you browse the content, and opens when the remote reaches it (DOWN from the top bar lands here).
    var open by remember { mutableStateOf(false) }
    val width by androidx.compose.animation.core.animateDpAsState(if (open) Tokens.sidebarWidth else 44.dp, label = "sidebar")
    val entryId = if (pins.any { pinId(it) == selectedId }) selectedId else pins.firstOrNull()?.let(pinId)
    Row(Modifier.fillMaxHeight().width(width).background(Tokens.panel).onFocusChanged { open = it.hasFocus }) {
        Column(Modifier.weight(1f).fillMaxHeight().padding(top = 8.dp)) {
            Column(Modifier.padding(horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                pins.forEach { pin ->
                    val id = pinId(pin)
                    SidebarRow(pin.title, id == selectedId, { onSelect(id) }, pin.icon(), open, if (id == entryId && entry != null) Modifier.focusRequester(entry) else Modifier)
                }
            }
            if (folders.isNotEmpty()) {
                Box(Modifier.padding(horizontal = 8.dp, vertical = 6.dp).fillMaxWidth().height(1.dp).background(Tokens.line))
                if (open) Eyebrow("Folders", Modifier.padding(horizontal = 18.dp, vertical = 4.dp))
                LazyColumn(Modifier.focusRestorer(), contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    items(folders, key = { it.id }) { cat -> SidebarRow(cat.name, cat.id == selectedId, { onSelect(cat.id) }, Icons.Filled.Folder, open) }
                }
            }
        }
        Box(Modifier.fillMaxHeight().width(1.dp).background(Tokens.line))
    }
}

@Composable
private fun SidebarRow(title: String, selected: Boolean, onClick: () -> Unit, icon: ImageVector, open: Boolean = true, modifier: Modifier = Modifier) {
    Focusable(onClick, modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x0AFFFFFF) else Color.Transparent,
        focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.02f) { focused ->
        // Moving down the list shows each entry's contents as the focus rests on it.
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(300); onClick() } }
        Row(Modifier.padding(horizontal = 8.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val tint = if (selected || focused) Tokens.accent else Tokens.textSecondary
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(tint))
            if (open) Label(title, Tokens.row, tint, if (selected) FontWeight.SemiBold else FontWeight.Normal)
        }
    }
}
