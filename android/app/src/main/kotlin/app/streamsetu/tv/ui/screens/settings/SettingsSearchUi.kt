package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

/**
 * The right-hand panel while Settings is being searched: a field, an option to include the technical settings (in Essential), and one vertical list of what matches. Everything is
 * searched in memory from [SettingsRegistry]; choosing a result opens the existing page and puts the remote on the existing control (see SettingFocusTarget). Search never changes a value.
 */
@Composable
fun SettingsSearchPanel(
    query: String, onQuery: (String) -> Unit, advancedMode: Boolean, includeAdvanced: Boolean, onIncludeAdvanced: (Boolean) -> Unit,
    fieldFocus: FocusRequester, restoreId: String?, onPick: (SettingDef) -> Unit, modifier: Modifier,
) {
    val results = remember(query, advancedMode, includeAdvanced) { SettingsRegistry.search(query, advancedMode || includeAdvanced) }
    val restore = remember { FocusRequester() }
    // Coming Back from a page that a result opened: the result the person chose has the remote again.
    LaunchedEffect(restoreId) { if (restoreId != null) { androidx.compose.runtime.withFrameNanos { }; androidx.compose.runtime.withFrameNanos { }; runCatching { restore.requestFocus() } } }
    LazyColumn(modifier, contentPadding = PaddingValues(start = 26.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item(key = "header") { Column(Modifier.padding(start = 12.dp, bottom = 6.dp)) { Label("Search settings", Mac.pageTitle, Tokens.text, FontWeight.Bold); Label("Type what you are looking for, for example subtitle size, DNS or buffer.", Mac.rowDetail, Tokens.textSecondary) } }
        item(key = "field") { Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(query, onQuery, "Search settings", Modifier.fillMaxWidth().focusRequester(fieldFocus)) } }
        if (!advancedMode) item(key = "advanced") { ToggleRow("Include advanced settings", "Also searches the technical settings that Essential leaves out.", includeAdvanced, onChange = onIncludeAdvanced) }
        if (query.isNotBlank() && results.isEmpty()) item(key = "none") { InfoRow("No setting matches", "", "Try another word, or include the advanced settings.") }
        items(results, key = { it.id }) { d ->
            SettingRow(d.title, d.category.title + if (d.description.isNotBlank()) "  ·  " + d.description.take(100) else "", chevron = true, modifier = if (d.id == restoreId) Modifier.focusRequester(restore) else Modifier) { onPick(d) }
        }
    }
}
