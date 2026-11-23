package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.repo.TmdbCast
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * What TMDB knows about the title on screen: its cast with photos and a wide picture. Opening the page asks at once (a key, or the built-in token, is all it needs): the title also goes to the
 * front of the artwork queue. A title in a locked or hidden folder, or with a copy in one, is never sent. What is shown stays until the answer replaces it (no clearing, no flicker); a
 * different title never keeps the previous one's answer. An answer that did not come (offline, busy) is asked for again a little later.
 */
@Composable
fun rememberTmdbDetails(c: AppContainer, id: String?, title: String, year: Int?, series: Boolean, categoryId: String?): TmdbCast.Details = rememberTmdbDetailsState(c, id, title, year, series, categoryId).details

/** What a title page knows from TMDB, and, when TMDB could not be asked or did not answer, why (in true words) and a way to try again. */
class TmdbDetailsState(val details: TmdbCast.Details, val problem: String?, val retry: () -> Unit)

@Composable
fun rememberTmdbDetailsState(c: AppContainer, id: String?, title: String, year: Int?, series: Boolean, categoryId: String?): TmdbDetailsState {
    val rev by c.folders.restrictRev.collectAsState("")
    var shown by remember(id, title, year, series) { mutableStateOf(TmdbCast.Details.NONE) }
    var problem by remember(id, title, year, series) { mutableStateOf<String?>(null) }
    var attempt by remember(id, title, year, series) { mutableIntStateOf(0) }
    LaunchedEffect(id, title, year, series, categoryId, rev, attempt) {
        if (!c.tmdbCast.enabled) { shown = TmdbCast.Details.NONE; problem = null; return@LaunchedEffect }
        val snap = c.folders.visibility.snapshot(Visibility.Surface.RECOMMEND)
        val kind = if (series) ContentKind.SERIES else ContentKind.MOVIE
        if (!snap.titleOk(kind, categoryId, title, year)) { shown = TmdbCast.Details.NONE; problem = null; return@LaunchedEffect }
        var tries = 0
        while (true) {
            // The express lane: match and details together, at once, apart from the bulk queue; the picture and summary are kept for the screen and the bulk run skips this title.
            val (d, failure) = c.artworkExpress.openChecked(id, title, year, series, categoryId)
            if (failure == null) problem = null
            if (d.cast.isNotEmpty() || d.backdrop != null || failure == null && c.tmdbCast.hasFresh(title, year, series) || ++tries >= 3) {
                if (d != TmdbCast.Details.NONE || shown == TmdbCast.Details.NONE) shown = d
                problem = failure?.let { c.describeTmdbProblem(it) }
                if (id != null && d.genres.isNotEmpty()) withContext(Dispatchers.IO) { c.tmdbGenres.put(id, d.genres) }          // the genre shelves read these before the folder names
                break
            }
            kotlinx.coroutines.delay(8_000L * tries)
        }
    }
    return TmdbDetailsState(shown, problem) { attempt++ }
}

/** A quiet line with a Retry button where the cast would be, when TMDB did not answer. */
@Composable
fun TmdbProblemLine(state: TmdbDetailsState, tv: Boolean) {
    val msg = state.problem ?: return
    Row(Modifier.padding(horizontal = if (tv) 32.dp else 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Label(msg, if (tv) Tokens.small else 13.sp, Tokens.textTertiary, modifier = Modifier.weight(1f, fill = false))
        if (tv) Focusable(state.retry, Modifier, shape = androidx.compose.foundation.shape.RoundedCornerShape(Tokens.radiusSmall), container = Tokens.card, browse = true) { _ -> Label("Retry", Tokens.small, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) }
        else Label("Retry", 13.sp, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp)).clickable(onClick = state.retry).padding(horizontal = 10.dp, vertical = 6.dp))
    }
}

/** A round photo (initials when TMDB has none), the name and the role under it. */
@Composable
fun CastPerson(m: TmdbCast.Member, size: androidx.compose.ui.unit.Dp, tv: Boolean, onClick: () -> Unit) {
    val photo: @Composable () -> Unit = {
        Box(Modifier.size(size).clip(CircleShape).background(Tokens.card), Alignment.Center) {
            if (m.photo.isNullOrBlank()) Label(m.name.split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1).uppercase() }, (size.value / 3).sp, Tokens.textSecondary, FontWeight.SemiBold)
            else AsyncImage(m.photo, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
    }
    val label: @Composable () -> Unit = {
        Label(m.name, if (tv) Tokens.small else 12.sp, Tokens.text, FontWeight.Medium, maxLines = 2, textAlign = TextAlign.Center)
        Label(m.role ?: " ", if (tv) Tokens.caption else 11.sp, Tokens.textTertiary, maxLines = 1, textAlign = TextAlign.Center)
    }
    if (tv) Focusable(onClick, Modifier.width(size + 28.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(Tokens.radius), container = androidx.compose.ui.graphics.Color.Transparent, browse = true) { _ ->
        Column(Modifier.padding(6.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) { photo(); label() }
    } else Column(Modifier.width(size + 12.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) { photo(); label() }
}

/** The row itself: nothing when there is no cast. */
@Composable
fun CastRow(cast: List<TmdbCast.Member>, tv: Boolean, onPerson: (TmdbCast.Member) -> Unit) {
    if (cast.isEmpty()) return
    LazyRow(if (tv) Modifier.bleedStart(24.dp).focusRestorer() else Modifier, horizontalArrangement = Arrangement.spacedBy(if (tv) 10.dp else 8.dp), contentPadding = PaddingValues(start = if (tv) 32.dp else 16.dp, end = 12.dp)) {
        items(cast, key = { it.id }, contentType = { "person" }) { m -> CastPerson(m, if (tv) 84.dp else 72.dp, tv) { onPerson(m) } }
    }
}
