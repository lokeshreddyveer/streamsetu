package app.streamsetu.tv.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.smartmix.GenreTable
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.Series
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterCard
import app.streamsetu.tv.ui.phone.PhonePoster
import app.streamsetu.tv.ui.theme.Tokens

/** Every title of one genre in the library, best rated first: where a genre shelf's "See all" and the "Browse by genre" row lead. Back returns to Home, to the same shelf. */
@Composable
fun GenreScreen(key: String, c: AppContainer, nav: Navigator, tv: Boolean) {
    val g = remember(key) { GenreTable.of(key) }
    var items by remember(key) { mutableStateOf<List<Any>?>(null) }
    LaunchedEffect(key) {
        val ids = runCatching { c.smartMix.genreTitles(key) }.getOrDefault(emptyList())
        val movies = c.catalog.moviesByIds(ids).associateBy { it.id }; val series = c.catalog.seriesByIds(ids).associateBy { it.id }
        items = ids.mapNotNull { movies[it] ?: series[it] }
    }
    BackHandler { nav.close() }
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyVerticalGrid(GridCells.Adaptive(if (tv) 154.dp else 104.dp), Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = if (tv) Tokens.safeHorizontal else 16.dp, end = if (tv) Tokens.safeHorizontal else 16.dp, top = if (tv) Tokens.safeVertical else 48.dp, bottom = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 10.dp), verticalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 12.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.padding(bottom = 8.dp)) {
                    Label(g?.name ?: "Genre", if (tv) Tokens.display else 24.sp, Tokens.text, FontWeight.Bold, maxLines = 2)
                    Label(items?.let { "%,d titles".format(it.size) } ?: " ", if (tv) Tokens.small else 13.sp, Tokens.textSecondary)
                }
            }
            items(items.orEmpty(), key = { (it as? Movie)?.id ?: (it as Series).id }) { t ->
                val m = t as? Movie; val s = t as? Series
                val title = m?.title ?: s!!.title; val url = m?.posterUrl ?: s?.posterUrl; val year = (m?.year ?: s?.year)?.toString()
                val open = { if (m != null) nav.open(Overlay.MovieDetail(m)) else nav.open(Overlay.SeriesDetail(s!!)) }
                if (tv) PosterCard(title, url, open, itemId = m?.id ?: s!!.id, subtitle = year) else PhonePoster(title, url, open, Modifier.fillMaxWidth(), itemId = m?.id ?: s!!.id, subtitle = year)
            }
        }
    }
}
