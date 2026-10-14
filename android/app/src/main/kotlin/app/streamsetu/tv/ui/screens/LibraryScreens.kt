package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

@Composable
private fun CategoryChips(categories: List<Category>, selected: String?, onSelect: (String) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 10.dp)) {
        items(categories, key = { it.id }) { cat ->
            Focusable({ onSelect(cat.id) }, container = if (cat.id == selected) Tokens.accent2 else Tokens.surface, scaleOnFocus = 1.05f) {
                Label(cat.name, Tokens.small, Tokens.text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp))
            }
        }
    }
}

@Composable
fun MoviesScreen(vm: MoviesViewModel, c: AppContainer, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    val selected by vm.selectedCategory.collectAsState()
    val movies by vm.movies.collectAsState()
    if (categories.isEmpty()) { EmptyState("No movies yet", "This playlist has no movies. Add one in Settings."); return }
    Column(Modifier.fillMaxSize().padding(top = 36.dp, end = Tokens.screenPadding)) {
        Label("Movies", Tokens.title, Tokens.text, FontWeight.Bold)
        CategoryChips(categories, selected ?: categories.first().id, vm::select)
        LazyVerticalGrid(GridCells.Adaptive(150.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(top = 8.dp, bottom = 48.dp)) {
            items(movies, key = { it.id }) { m -> PosterCard(m.title, m.posterUrl, { play(c, nav, MoviePlayable(m)) }) }
        }
    }
}

@Composable
fun SeriesScreen(vm: SeriesViewModel, nav: Navigator) {
    val categories by vm.categories.collectAsState()
    val selected by vm.selectedCategory.collectAsState()
    val series by vm.series.collectAsState()
    if (categories.isEmpty()) { EmptyState("No series yet", "This playlist has no series. Add an Xtream playlist in Settings."); return }
    Column(Modifier.fillMaxSize().padding(top = 36.dp, end = Tokens.screenPadding)) {
        Label("Series", Tokens.title, Tokens.text, FontWeight.Bold)
        CategoryChips(categories, selected ?: categories.first().id, vm::select)
        LazyVerticalGrid(GridCells.Adaptive(150.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(top = 8.dp, bottom = 48.dp)) {
            items(series, key = { it.id }) { s -> PosterCard(s.title, s.posterUrl, { nav.open(Overlay.SeriesDetail(s)) }) }
        }
    }
}

/** A series: its episodes by season. OK on an episode plays it, and the next episodes queue up behind it. */
@Composable
fun SeriesDetailScreen(vm: SeriesDetailViewModel, c: AppContainer, nav: Navigator) {
    val episodes by vm.episodes.collectAsState()
    val loading by vm.loading.collectAsState()
    val error by vm.error.collectAsState()
    val progress by vm.progress.collectAsState()
    val s = vm.series
    val seasons = episodes.groupBy { it.season }.toSortedMap()
    var season by remember(seasons.keys) { mutableStateOf(seasons.keys.firstOrNull() ?: 1) }
    val queue = remember(episodes) { episodes.map { EpisodePlayable(it, s) } }

    Box(Modifier.fillMaxSize().padding(start = 48.dp, top = 36.dp, end = Tokens.screenPadding).background(Tokens.background)) {
        Column {
            Label(s.title, Tokens.title, Tokens.text, FontWeight.Bold)
            s.plot?.let { Label(it, Tokens.small, Tokens.muted, maxLines = 3, modifier = Modifier.padding(vertical = 8.dp).widthIn(max = 900.dp)) }
            if (loading && episodes.isEmpty()) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading episodes…", color = Tokens.muted) }
            error?.let { if (episodes.isEmpty()) Label(it, color = Tokens.danger) }
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
                items(seasons.keys.toList()) { n ->
                    Focusable({ season = n }, container = if (n == season) Tokens.accent2 else Tokens.surface, scaleOnFocus = 1.05f) { Label("Season $n", Tokens.small, modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp)) }
                }
            }
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
                items(seasons[season].orEmpty(), key = { it.id }) { e ->
                    val p = progress[e.id]
                    Focusable({ play(c, nav, EpisodePlayable(e, s), queue) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.02f) {
                        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Label("${e.number}", Tokens.heading, Tokens.accent, FontWeight.Bold, modifier = Modifier.width(44.dp))
                            Column(Modifier.weight(1f)) {
                                Label(e.title, weight = FontWeight.SemiBold)
                                e.plot?.let { Label(it, Tokens.small, Tokens.muted, maxLines = 2) }
                            }
                            if (p?.completed == true) Label("Watched", Tokens.small, Tokens.success)
                            else if (p != null && p.fraction > 0) Label("${(p.fraction * 100).toInt()}%", Tokens.small, Tokens.accent)
                        }
                    }
                }
            }
        }
    }
}

