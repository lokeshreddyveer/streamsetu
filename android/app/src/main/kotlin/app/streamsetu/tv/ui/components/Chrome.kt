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

/** The Mac's top bar: the brand on the left, the five sections in the middle, search and settings on the right. */
@Composable
fun TopBar(selected: Tab, first: FocusRequester, onHasFocus: (Boolean) -> Unit = {}, onSelect: (Tab) -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(Tokens.headerHeight).background(Tokens.panel).padding(horizontal = Tokens.screenPadding).onFocusChanged { onHasFocus(it.hasFocus) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Label("StreamSetu", Tokens.heading, Tokens.accent, FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.GUIDE).forEach { tab ->
                TopTab(tab.title, tab == selected, { onSelect(tab) }, if (tab == selected) Modifier.focusRequester(first) else Modifier)
            }
        }
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTab(Icons.Filled.Search, "Search", selected == Tab.SEARCH, if (selected == Tab.SEARCH) Modifier.focusRequester(first) else Modifier) { onSelect(Tab.SEARCH) }
            IconTab(Icons.Filled.Settings, "Settings", selected == Tab.SETTINGS, if (selected == Tab.SETTINGS) Modifier.focusRequester(first) else Modifier) { onSelect(Tab.SETTINGS) }
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Tokens.line))
}

@Composable
private fun TopTab(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent,
        focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.04f) { focused ->
        // Moving along the bar shows each section as the focus rests on it; no need to press OK.
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); onClick() } }
        androidx.compose.foundation.text.BasicText(title, Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
            style = androidx.compose.ui.text.TextStyle(color = if (selected || focused) Tokens.accent else Tokens.textSecondary, fontSize = Tokens.row, fontWeight = FontWeight.SemiBold), maxLines = 1, softWrap = false)
    }
}

@Composable
private fun IconTab(icon: ImageVector, label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent, focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.08f) { focused ->
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); onClick() } }
        Image(icon, label, Modifier.padding(8.dp).size(20.dp), colorFilter = ColorFilter.tint(if (selected || focused) Tokens.accent else Tokens.textSecondary))
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
    Row(Modifier.fillMaxHeight().width(Tokens.sidebarWidth).background(Tokens.panel)) {
        Column(Modifier.weight(1f).fillMaxHeight().padding(top = 8.dp)) {
            Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                pins.forEach { pin ->
                    val id = pinId(pin)
                    SidebarRow(pin.title, id == selectedId, { onSelect(id) }, pin.icon())
                }
            }
            if (folders.isNotEmpty()) {
                Box(Modifier.padding(horizontal = 8.dp, vertical = 6.dp).fillMaxWidth().height(1.dp).background(Tokens.line))
                Eyebrow("Folders", Modifier.padding(horizontal = 18.dp, vertical = 4.dp))
                LazyColumn(Modifier.focusRestorer(), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    items(folders, key = { it.id }) { cat -> SidebarRow(cat.name, cat.id == selectedId, { onSelect(cat.id) }, Icons.Filled.Folder) }
                }
            }
        }
        Box(Modifier.fillMaxHeight().width(1.dp).background(Tokens.line))
    }
}

@Composable
private fun SidebarRow(title: String, selected: Boolean, onClick: () -> Unit, icon: ImageVector) {
    Focusable(onClick, Modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x0AFFFFFF) else Color.Transparent,
        focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.02f) { focused ->
        // Moving down the list shows each entry's contents as the focus rests on it.
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(300); onClick() } }
        Row(Modifier.padding(horizontal = 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            val tint = if (selected || focused) Tokens.accent else Tokens.textSecondary
            Image(icon, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(tint))
            Label(title, Tokens.row, tint, if (selected) FontWeight.SemiBold else FontWeight.Normal)
        }
    }
}
