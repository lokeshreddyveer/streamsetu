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
import app.streamsetu.core.data.repo.FilmTile
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

/**
 * A person's page: who they are (TMDB), then their whole filmography as posters, each marked "In your library" or not, with "All films" and "In your library" buttons. Nothing about the library
 * leaves the device: TMDB gets the person id (or an exact name) only. Without a credential, or offline with nothing saved, it falls back to the titles the local cast index knows.
 */
@Composable
fun PersonScreen(name: String, photo: String?, c: AppContainer, nav: Navigator, tv: Boolean, personId: Long? = null, fromTitle: String? = null, fromYear: Int? = null) {
    val rev by c.folders.restrictRev.collectAsState("")
    val sources by c.library.sourceIds.collectAsState()
    val libraryOnly by c.ui.personLibraryOnly.collectAsState()
    val actingOnly by c.ui.personActingOnly.collectAsState()
    val uiLang by c.ui.language.collectAsState()
    var state by remember(name, personId) { mutableStateOf(PersonPageState()) }
    val lang = remember(uiLang) { if (uiLang == "SYSTEM") java.util.Locale.getDefault().language.ifEmpty { "en" } else uiLang }
    var attempt by remember(name, personId) { mutableIntStateOf(0) }
    LaunchedEffect(name, personId, rev, sources, lang, attempt) {
        val loader = PersonPageLoader(c.tmdbPeople, c.libraryMatcher, { n -> personTitles(c, n) }, { sources }, c::describeTmdbProblem)
        loader.load(name, personId, fromTitle, lang) { state = it }
    }
    val open: (FilmTile) -> Unit = { t -> t.hit?.movie?.let { nav.open(Overlay.MovieDetail(it)) } ?: t.hit?.series?.let { nav.open(Overlay.SeriesDetail(it)) } }
    val back = remember { { PersonMemory.clear(); nav.close() } }
    androidx.activity.compose.BackHandler(onBack = back)
    PersonContent(name, photo, state, tv, libraryOnly, { c.ui.setPersonLibraryOnly(it) }, open, kids = app.streamsetu.tv.KidsLock.on, actingOnly = actingOnly, onActingOnly = { c.ui.setPersonActingOnly(it) }, onRetry = { attempt++ })
}
