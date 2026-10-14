package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens

/** Kept for the Settings page list; the rest of the app uses category chips. */
val LocalSidebarEntry = androidx.compose.runtime.compositionLocalOf<FocusRequester?> { null }

/**
 * The top bar of a streaming app: brand on the left, sections in the middle, search and settings on the right.
 * Over the full-bleed picture on Home it is transparent with a soft shade; on other pages it is a solid bar.
 */
@Composable
fun TopBar(selected: Tab, first: FocusRequester, transparent: Boolean, onHasFocus: (Boolean) -> Unit = {}, canAutoSelect: () -> Boolean = { true }, onSelect: (Tab) -> Unit) {
    Box(
        Modifier.fillMaxWidth().height(Tokens.headerHeight)
            .background(if (transparent) Brush.verticalGradient(listOf(Color(0xCC05070B), Color(0x0005070B))) else Brush.verticalGradient(listOf(Tokens.panel, Tokens.panel)))
            .onFocusChanged { onHasFocus(it.hasFocus) },
    ) {
        Row(Modifier.fillMaxSize().padding(horizontal = Tokens.screenPadding), verticalAlignment = Alignment.CenterVertically) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(24.dp).background(Tokens.accent, RoundedCornerShape(7.dp)), Alignment.Center) { Label("▶", 11.sp, Color(0xFF06121A), FontWeight.Bold) }
                Label("StreamSetu", Tokens.heading, Tokens.text, FontWeight.Bold)
            }
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
                listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.GUIDE).forEach { tab ->
                    TopTab(tab.title, tab == selected, { onSelect(tab) }, if (tab == selected) Modifier.focusRequester(first) else Modifier, canAutoSelect)
                }
            }
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTab(Icons.Filled.Search, "Search", selected == Tab.SEARCH, if (selected == Tab.SEARCH) Modifier.focusRequester(first) else Modifier, canAutoSelect) { onSelect(Tab.SEARCH) }
                IconTab(Icons.Filled.Settings, "Settings", selected == Tab.SETTINGS, if (selected == Tab.SETTINGS) Modifier.focusRequester(first) else Modifier, canAutoSelect) { onSelect(Tab.SETTINGS) }
            }
        }
        if (!transparent) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(1.dp).background(Tokens.line))
    }
}

@Composable
private fun TopTab(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, canAutoSelect: () -> Boolean = { true }) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = if (selected) Tokens.accent.copy(alpha = 0.18f) else Color.Transparent,
        focusedContainer = if (selected) Tokens.accent.copy(alpha = 0.3f) else Color(0x26FFFFFF), scaleOnFocus = 1.03f) { focused ->
        // Moving along the bar shows each section as the focus rests on it; no need to press OK.
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); if (canAutoSelect()) onClick() } }
        androidx.compose.foundation.text.BasicText(title, Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
            style = androidx.compose.ui.text.TextStyle(color = if (selected || focused) (if (selected) Tokens.accent else Tokens.text) else Tokens.textSecondary, fontSize = Tokens.nav, fontWeight = FontWeight.SemiBold), maxLines = 1, softWrap = false)
    }
}

@Composable
private fun IconTab(icon: ImageVector, label: String, selected: Boolean, modifier: Modifier = Modifier, canAutoSelect: () -> Boolean = { true }, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = if (selected) Tokens.accent.copy(alpha = 0.18f) else Color.Transparent, focusedContainer = Color(0x26FFFFFF), scaleOnFocus = 1.08f) { focused ->
        LaunchedEffect(focused) { if (focused && !selected) { kotlinx.coroutines.delay(350); if (canAutoSelect()) onClick() } }
        Image(icon, label, Modifier.padding(7.dp).size(18.dp), colorFilter = ColorFilter.tint(if (selected) Tokens.accent else if (focused) Tokens.text else Tokens.textSecondary))
    }
}

data class Chip(val id: String, val title: String, val icon: ImageVector? = null)

/**
 * A row of category pills under the top bar (Featured, All, Recently Added, then the provider's folders).
 * DOWN from the top bar lands here; moving along it shows each category as the focus rests on it.
 */
@Composable
fun ChipRow(chips: List<Chip>, selected: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier, moreLabel: String? = null, moreSelected: Boolean = false, onMore: (() -> Unit)? = null) {
    // DOWN from the top bar lands on the category that is open now (not on whichever pill is nearest), so nothing changes until you choose.
    val entry = remember { FocusRequester() }
    val hasSelected = moreSelected || chips.any { it.id == selected }
    LazyRow(modifier.fillMaxWidth().focusProperties { enter = { if (hasSelected) entry else FocusRequester.Default } }, contentPadding = PaddingValues(horizontal = Tokens.screenPadding, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(chips, key = { it.id }) { chip ->
            val sel = chip.id == selected && !moreSelected
            Pill(chip.title, chip.icon, sel, modifier = if (sel) Modifier.focusRequester(entry) else Modifier) { onSelect(chip.id) }
        }
        // There can be hundreds of provider folders: one pill opens the whole list instead of a row that never ends.
        if (onMore != null) item(key = "__more") { Pill(moreLabel ?: "Categories", Icons.Filled.Folder, moreSelected, trailing = Icons.Filled.ArrowDropDown, autoSelect = false, modifier = if (moreSelected) Modifier.focusRequester(entry) else Modifier) { onMore() } }
    }
}

@Composable
private fun Pill(title: String, icon: ImageVector?, sel: Boolean, trailing: ImageVector? = null, autoSelect: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = if (sel) Tokens.text else Tokens.elevated,
        focusedContainer = if (sel) Tokens.text else Color(0xFF2A3140), scaleOnFocus = 1.05f) { f ->
        if (autoSelect) LaunchedEffect(f) { if (f && !sel) { kotlinx.coroutines.delay(320); onClick() } }
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (icon != null) Image(icon, null, Modifier.size(13.dp), colorFilter = ColorFilter.tint(if (sel) Color(0xFF0B0D12) else Tokens.textSecondary))
            Label(title, Tokens.small, if (sel) Color(0xFF0B0D12) else Tokens.text, if (sel) FontWeight.Bold else FontWeight.Medium, modifier = Modifier.widthIn(max = 260.dp))
            if (trailing != null) Image(trailing, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(if (sel) Color(0xFF0B0D12) else Tokens.textSecondary))
        }
    }
}

/** The full list of the provider's folders in a drawer on the left: scroll with up / down, OK picks, Back closes. */
@Composable
fun CategoryPicker(title: String, folders: List<Chip>, selected: String, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        val state = androidx.compose.foundation.lazy.rememberLazyListState()
        val target = remember { FocusRequester() }
        var query by remember { mutableStateOf("") }
        val shown = if (query.isBlank()) folders else folders.filter { it.title.contains(query.trim(), ignoreCase = true) }
        val index = if (query.isBlank()) folders.indexOfFirst { it.id == selected }.coerceAtLeast(0) else 0
        LaunchedEffect(Unit) { state.scrollToItem((index - 3).coerceAtLeast(0)); kotlinx.coroutines.delay(150); runCatching { target.requestFocus() } }
        Row(Modifier.fillMaxSize().background(Color(0xB3000000))) {
            Column(Modifier.width(340.dp).fillMaxHeight().background(Tokens.panel).padding(top = 18.dp)) {
                Label(title, Tokens.heading, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(horizontal = 20.dp))
                Label(if (query.isBlank()) "${folders.size} categories" else "${shown.size} of ${folders.size}", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp))
                Spacer(Modifier.height(6.dp))
                TvTextField(query, { query = it }, "Search categories", Modifier.padding(horizontal = 12.dp).fillMaxWidth())
                Spacer(Modifier.height(6.dp))
                androidx.compose.foundation.lazy.LazyColumn(state = state, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    itemsIndexed(shown, key = { _, f -> f.id }) { i, f ->
                        val sel = f.id == selected
                        Focusable({ onPick(f.id) }, (if (i == index) Modifier.focusRequester(target) else Modifier).fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall),
                            container = if (sel) Color(0x14FFFFFF) else Color.Transparent, focusedContainer = Color(0x26FFFFFF), scaleOnFocus = 1.0f) { focused ->
                            Row(Modifier.padding(horizontal = 10.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                                Image(Icons.Filled.Folder, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(if (sel || focused) Tokens.accent else Tokens.textSecondary))
                                Label(f.title, Tokens.row, if (sel || focused) Tokens.text else Tokens.textSecondary, if (sel) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.weight(1f))
                                if (sel) Image(Icons.Filled.Check, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                            }
                        }
                    }
                }
            }
        }
    }
}
