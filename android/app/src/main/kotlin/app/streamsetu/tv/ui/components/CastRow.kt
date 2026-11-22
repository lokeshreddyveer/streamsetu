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
 * The cast of a title from TMDB: with no key of the person's own there is none (nothing is asked), and a title in a locked or hidden folder, or with a copy in one, is never sent.
 * Read once per title (saved for 30 days), off the main thread.
 */
@Composable
fun rememberCast(c: AppContainer, title: String, year: Int?, series: Boolean, categoryId: String?): List<TmdbCast.Member> {
    // Read again whenever a lock, hide or profile changes who may see this title; the previous title's cast is never kept (cleared first, and a stale load is cancelled by the new key).
    val rev by c.folders.restrictRev.collectAsState("")
    val state = produceState(emptyList<TmdbCast.Member>(), title, year, series, categoryId, rev) {
        value = emptyList()
        if (!c.tmdbCast.enabled) return@produceState
        val snap = c.folders.visibility.snapshot(Visibility.Surface.RECOMMEND)
        val kind = if (series) ContentKind.SERIES else ContentKind.MOVIE
        if (!snap.titleOk(kind, categoryId, title, year)) return@produceState
        value = withContext(Dispatchers.IO) { c.tmdbCast.cast(title, year, series) }
    }
    return state.value
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
