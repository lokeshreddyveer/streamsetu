package app.streamsetu.tv.ui.screens.section

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.TitleLanguages
import app.streamsetu.core.model.CollectionRule
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.SmartCollection
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.settings.ChoiceRow
import app.streamsetu.tv.ui.screens.settings.InfoRow
import app.streamsetu.tv.ui.screens.settings.SettingGroup
import app.streamsetu.tv.ui.screens.settings.ToggleRow
import app.streamsetu.tv.ui.theme.Tokens
import androidx.compose.ui.window.DialogProperties

private enum class Released(val label: String, val from: Int?, val to: Int?) {
    ANY("Any year", null, null), RECENT("Last two years", java.time.Year.now().value - 1, null), TWENTY_TWENTIES("2020s", 2020, 2029), TWENTY_TENS("2010s", 2010, 2019),
    TWO_THOUSANDS("2000s", 2000, 2009), OLDER("Before 2000", null, 1999);
    companion object { fun of(r: CollectionRule) = entries.firstOrNull { it.from == r.yearFrom && it.to == r.yearTo } ?: ANY }
}

/**
 * A form for a smart collection: a name and any of the choices below, all of which have to hold. It shows in words what the list will match and says what is wrong before it will save. Everything
 * is chosen from lists the app already knows (languages, years, ratings, connections) or typed as a few plain words; nothing typed is ever put into a query as code.
 */
@Composable
fun SmartCollectionEditor(c: AppContainer, kind: ContentKind, existing: SmartCollection?, onSaved: (String) -> Unit, onClose: () -> Unit) {
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var rule by remember { mutableStateOf(existing?.rule ?: CollectionRule()) }
    var error by remember { mutableStateOf<String?>(null) }
    val sources by c.sources.sources.collectAsState(initial = emptyList())
    val problems = remember(rule) { rule.problems() }
    TvDialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().dialogScrim(), Alignment.Center) {
            Column(Modifier.width(760.dp).heightIn(max = 640.dp).background(Tokens.panel, RoundedCornerShape(Tokens.radiusPanel)).padding(24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label(if (existing == null) "New smart collection" else "Edit smart collection", Tokens.title, Tokens.text, FontWeight.Bold)
                Label("Fills itself with every ${if (kind == ContentKind.MOVIE) "movie" else "series"} that matches all of your choices.", Tokens.small, Tokens.textSecondary)
                Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    TvTextField(name, { name = it.take(60) }, "Name", Modifier.fillMaxWidth())
                    SettingGroup("Match") {
                        ChoiceRow("Language", options = listOf<Pair<String?, String>>(null to "Any") + TitleLanguages.known.map { it to it }, value = rule.language) { rule = rule.copy(language = it) }
                        ChoiceRow("Released", options = Released.entries.map { it to it.label }, value = Released.of(rule)) { rule = rule.copy(yearFrom = it.from, yearTo = it.to) }
                        ChoiceRow("Rating", options = listOf<Pair<Double?, String>>(null to "Any", 5.0 to "5 or higher", 6.0 to "6 or higher", 7.0 to "7 or higher", 8.0 to "8 or higher"), value = rule.minRating) { rule = rule.copy(minRating = it) }
                        ChoiceRow("Added", options = listOf<Pair<Int?, String>>(null to "Any time", 7 to "Last 7 days", 30 to "Last 30 days", 90 to "Last 90 days"), value = rule.addedWithinDays) { rule = rule.copy(addedWithinDays = it) }
                        ToggleRow("Only what I have not watched", null, rule.unwatched) { rule = rule.copy(unwatched = it) }
                        ToggleRow("Only my favourites", null, rule.favoritesOnly) { rule = rule.copy(favoritesOnly = it) }
                        ChoiceRow("From", options = listOf<Pair<String?, String>>(null to "Every connection") + sources.filter { !it.draft }.map { it.id to it.name }, value = rule.sourceId) { rule = rule.copy(sourceId = it) }
                    }
                    SettingGroup("Words") {
                        Box(Modifier.padding(horizontal = 10.dp, vertical = 4.dp)) { TvTextField(rule.titleContains.orEmpty(), { rule = rule.copy(titleContains = it.take(80).ifBlank { null }) }, "Title contains", Modifier.fillMaxWidth()) }
                        Box(Modifier.padding(horizontal = 10.dp, vertical = 4.dp)) { TvTextField(rule.folderContains.orEmpty(), { rule = rule.copy(folderContains = it.take(80).ifBlank { null }) }, "Folder name contains", Modifier.fillMaxWidth()) }
                    }
                    InfoRow("It will match", "", rule.describe { id -> sources.firstOrNull { it.id == id }?.name })
                    problems.forEach { InfoRow("Not yet", "", it) }
                    error?.let { InfoRow("Could not save", "", it) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvButton(if (existing == null) "Create" else "Save", {
                        val r = if (existing == null) c.smartCollections.add(name, kind, rule) else c.smartCollections.update(existing.id, name, rule).map { existing.id }
                        r.onSuccess { onSaved(it) }.onFailure { error = it.message }
                    }, primary = true)
                    TvButton("Cancel", onClose)
                }
            }
        }
    }
}
