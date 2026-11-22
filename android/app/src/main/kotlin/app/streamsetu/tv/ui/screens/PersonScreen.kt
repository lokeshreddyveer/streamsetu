package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterCard
import app.streamsetu.tv.ui.phone.PhonePoster
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** One title of a person in the library, once: the copy shown first and how many language versions the library holds. */
data class PersonTitle(val movie: Movie?, val series: Series?, val versions: Int) {
    val id get() = movie?.id ?: series!!.id
    val title get() = movie?.title ?: series!!.title
    val posterUrl get() = movie?.posterUrl ?: series?.posterUrl
    val year get() = movie?.year ?: series?.year
}

/**
 * The titles of one person that exist in the library (the local cast index, the same one Search uses), each title once however many language versions it has, with the strictest-but-search
 * rules applied: nothing in a locked, hidden or adult-blocked folder, and no title with a copy in one.
 */
suspend fun personTitles(c: AppContainer, name: String, limit: Int = 120): List<PersonTitle> = personTitles(c.db, c.catalog, c.folders.visibility, c.library.sourceIds.value.toList(), name, limit)

suspend fun personTitles(db: app.streamsetu.core.data.db.AppDatabase, catalog: app.streamsetu.core.data.repo.CatalogRepository, visibility: Visibility, sources: List<String>, name: String, limit: Int = 120): List<PersonTitle> = withContext(Dispatchers.IO) {
    val words = SearchText.normalize(name).split(' ').filter { it.isNotEmpty() }
    val hits = PeopleIndex.hits(db.openHelper.readableDatabase, words, sources, listOf("MOVIE", "SERIES"), limit * 3)
    val snap = visibility.snapshot(Visibility.Surface.RECOMMEND)          // the strictest rule: a title with a copy in a restricted folder is out too
    val movies = catalog.moviesByIds(hits.filter { it.kind == "MOVIE" }.map { it.itemId }).associateBy { it.id }
    val series = catalog.seriesByIds(hits.filter { it.kind == "SERIES" }.map { it.itemId }).associateBy { it.id }
    val groups = LinkedHashMap<String, MutableList<PersonTitle>>()
    for (h in hits) {
        val t = if (h.kind == "SERIES") series[h.itemId]?.takeIf(snap::seriesOk)?.let { PersonTitle(null, it, 1) } else movies[h.itemId]?.takeIf(snap::movieOk)?.let { PersonTitle(it, null, 1) }
        if (t == null) continue
        groups.getOrPut((if (t.series != null) "S" else "M") + IdentityKey.ofOrFallback(t.title) + "|" + ((t.year ?: 0) / 2)) { ArrayList(1) } += t
    }
    groups.values.map { g -> g.first().copy(versions = g.size) }.take(limit)
}

/** A person's page: their photo and name, then their titles in this library. */
@Composable
fun PersonScreen(name: String, photo: String?, c: AppContainer, nav: Navigator, tv: Boolean) {
    var titles by remember(name) { mutableStateOf<List<PersonTitle>?>(null) }
    LaunchedEffect(name) { titles = runCatching { personTitles(c, name) }.getOrDefault(emptyList()) }
    val open: (PersonTitle) -> Unit = { t -> t.movie?.let { nav.open(Overlay.MovieDetail(it)) } ?: t.series?.let { nav.open(Overlay.SeriesDetail(it)) } }
    val back = remember { { nav.close() } }
    androidx.activity.compose.BackHandler(onBack = back)
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyVerticalGrid(GridCells.Adaptive(if (tv) 154.dp else 104.dp), Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = if (tv) Tokens.safeHorizontal else 16.dp, end = if (tv) Tokens.safeHorizontal else 16.dp, top = if (tv) Tokens.safeVertical else 48.dp, bottom = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 10.dp), verticalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 12.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }, key = "header") {
                Row(Modifier.padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Box(Modifier.size(if (tv) 96.dp else 72.dp).clip(CircleShape).background(Tokens.card), Alignment.Center) {
                        if (photo.isNullOrBlank()) Label(name.take(1).uppercase(), 28.androidx(), Tokens.textSecondary, FontWeight.SemiBold) else AsyncImage(photo, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    }
                    Column {
                        Label(name, if (tv) Tokens.display else 22.androidx(), Tokens.text, FontWeight.Bold, maxLines = 2)
                        Label(titles?.let { if (it.isEmpty()) "Nothing in your library yet" else "%,d in your library".format(it.size) } ?: "Looking in your library…", Tokens.small, Tokens.textSecondary)
                    }
                }
            }
            items(titles.orEmpty(), key = { it.id }, contentType = { "poster" }) { t ->
                val sub = listOfNotNull(t.year?.toString(), if (t.versions > 1) "${t.versions} languages" else null).joinToString(" · ").ifEmpty { " " }
                if (tv) PosterCard(t.title, t.posterUrl, { open(t) }, itemId = t.id, subtitle = sub)
                else PhonePoster(t.title, t.posterUrl, { open(t) }, Modifier.fillMaxWidth(), itemId = t.id, subtitle = sub)
            }
        }
    }
}

private fun Int.androidx() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Sp)
