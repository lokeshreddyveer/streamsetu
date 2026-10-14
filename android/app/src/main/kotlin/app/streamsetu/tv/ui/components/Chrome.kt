package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.Category
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens

/** The Mac's top bar: the brand on the left, the sections in the middle, search and settings on the right. */
@Composable
fun TopBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    Row(
        Modifier.fillMaxWidth().height(Tokens.headerHeight).background(Tokens.panel).padding(horizontal = 32.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Label("StreamSetu", Tokens.heading, Tokens.accent, FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        // The sections keep their full names: the row is never squeezed into "…".
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf(Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES, Tab.FAVOURITES).forEach { tab ->
                TopTab(tab.title, tab == selected, { onSelect(tab) }, if (tab == selected) Modifier.focusRequester(first) else Modifier)
            }
        }
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTab(Icons.Filled.Search, "Search", selected == Tab.SEARCH) { onSelect(Tab.SEARCH) }
            IconTab(Icons.Filled.Settings, "Settings", selected == Tab.SETTINGS) { onSelect(Tab.SETTINGS) }
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Tokens.line))
}

@Composable
private fun TopTab(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent,
        focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.04f) { focused ->
        androidx.compose.foundation.text.BasicText(title, Modifier.padding(horizontal = 13.dp, vertical = 9.dp), style = androidx.compose.ui.text.TextStyle(color = if (selected || focused) Tokens.accent else Tokens.textSecondary, fontSize = Tokens.row, fontWeight = FontWeight.SemiBold), maxLines = 1, softWrap = false)
    }
}

@Composable
private fun IconTab(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    Focusable(onClick, shape = RoundedCornerShape(Tokens.radiusSmall), container = if (selected) Color(0x14FFFFFF) else Color.Transparent, focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.08f) { focused ->
        Image(icon, label, Modifier.padding(10.dp).size(24.dp), colorFilter = ColorFilter.tint(if (selected || focused) Tokens.accent else Tokens.textSecondary))
    }
}

/**
 * The Mac's contextual sidebar: a title in spaced capitals, then the folders (categories) of this section. Only this list scrolls.
 * The selected folder shows in the accent colour on a faint white wash; the sidebar sits on the panel colour with a hairline on its right.
 */
@Composable
fun ContextSidebar(title: String, categories: List<Category>, selectedId: String?, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxHeight().width(Tokens.sidebarWidth).background(Tokens.panel)) {
        Column(Modifier.weight(1f).fillMaxHeight().padding(top = 18.dp)) {
            Eyebrow(title, Modifier.padding(horizontal = 24.dp, vertical = 8.dp), Tokens.textSecondary)
            LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items(categories, key = { it.id }) { cat ->
                    val sel = cat.id == selectedId
                    Focusable({ onSelect(cat.id) }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall),
                        container = if (sel) Color(0x0AFFFFFF) else Color.Transparent, focusedContainer = Color(0x1FFFFFFF), scaleOnFocus = 1.02f) { focused ->
                        Label(cat.name, Tokens.row, if (sel || focused) Tokens.accent else Tokens.textSecondary, if (sel) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.padding(horizontal = 12.dp, vertical = 11.dp))
                    }
                }
            }
        }
        Box(Modifier.fillMaxHeight().width(1.dp).background(Tokens.line))
    }
}
