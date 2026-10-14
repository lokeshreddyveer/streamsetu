package app.streamsetu.tv.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.sync.SyncService
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

/**
 * The full-bleed picture at the top of Home, like a streaming service: a big backdrop behind the top bar, the title, facts, a short story,
 * and Play / More Info. It changes every few seconds and is a new mix each launch.
 */
@Composable
fun Hero(items: List<Playable>, loadInfo: suspend (Movie) -> SyncService.MovieInfo?, onPlay: (Playable) -> Unit, onDetails: (Playable) -> Unit, modifier: Modifier = Modifier) {
    if (items.isEmpty()) return
    var index by remember(items) { mutableIntStateOf(0) }
    var focusedInside by remember { mutableStateOf(false) }
    LaunchedEffect(items, focusedInside) { while (!focusedInside) { delay(9000); index = (index + 1) % items.size } }
    val item = items[index.coerceIn(0, items.lastIndex)]
    var info by remember(item.id) { mutableStateOf<SyncService.MovieInfo?>(null) }
    LaunchedEffect(item.id) { if (item is MoviePlayable) info = runCatching { loadInfo(item.movie) }.getOrNull() }

    Box(modifier.fillMaxWidth().height(340.dp).background(Tokens.background)) {
        Crossfade(item.id, label = "hero") { _ ->
            val backdrop = when (item) {
                is SeriesFeature -> item.series.backdropUrl?.takeIf { it.isNotBlank() }
                is MoviePlayable -> info?.backdrop?.takeIf { it.isNotBlank() }
                else -> item.artworkUrl?.takeIf { it.isNotBlank() }
            }
            val poster = when (item) { is SeriesFeature -> item.series.posterUrl; is MoviePlayable -> item.movie.posterUrl; else -> null }?.takeIf { it.isNotBlank() }
            Box(Modifier.fillMaxSize()) {
                PosterPlaceholder(item.title, Modifier.fillMaxSize())
                if (backdrop != null) AsyncImage(backdrop, item.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.TopCenter)
                else if (poster != null) {
                    // No wide picture from the provider: a blurred-looking big poster behind, and the poster itself on the right.
                    AsyncImage(poster, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.Center, alpha = 0.35f)
                    AsyncImage(poster, item.title, Modifier.align(Alignment.CenterEnd).padding(end = 90.dp, top = 30.dp).height(270.dp).aspectRatio(150f / 218f).clip(RoundedCornerShape(10.dp)), contentScale = ContentScale.Crop)
                }
            }
        }
        // Soft shades so text is always readable, and the picture melts into the rows below.
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Color(0xF20B0D12), 0.45f to Color(0xA60B0D12), 1f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.55f to Color.Transparent, 1f to Tokens.background)))

        Column(Modifier.align(Alignment.BottomStart).padding(start = Tokens.screenPadding, bottom = 30.dp).widthIn(max = 470.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Eyebrow(if (item is SeriesFeature) "Series" else "Movie", color = Tokens.accent)
            Label(item.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
            val facts = when (item) {
                is SeriesFeature -> listOfNotNull(item.series.year?.toString(), item.series.rating?.toDoubleOrNull()?.takeIf { it > 0 }?.let { "★ " + String.format("%.1f", it) })
                is MoviePlayable -> listOfNotNull(item.movie.year?.toString(), info?.genre, item.movie.rating?.toDoubleOrNull()?.takeIf { it > 0 }?.let { "★ " + String.format("%.1f", it) })
                else -> emptyList()
            }
            if (facts.isNotEmpty()) Label(facts.joinToString("   ·   "), Tokens.small, Tokens.textSecondary)
            val plot = when (item) { is SeriesFeature -> item.series.plot; is MoviePlayable -> info?.plot ?: item.movie.plot; else -> null }
            if (!plot.isNullOrBlank()) Label(plot, Tokens.small, Tokens.textSecondary, maxLines = 3)
            Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton(if (item is SeriesFeature) "Episodes" else "Play", { if (item is SeriesFeature) onDetails(item) else onPlay(item) }, (LocalContentEntry.current?.let { Modifier.focusRequester(it) } ?: Modifier), icon = Icons.Filled.PlayArrow, primary = true, onFocus = { focusedInside = it })
                TvButton("More Info", { onDetails(item) }, icon = Icons.Filled.Info, onFocus = { focusedInside = it })
            }
        }
        Row(Modifier.align(Alignment.BottomEnd).padding(end = Tokens.screenPadding, bottom = 36.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            items.indices.forEach { i -> Box(Modifier.size(if (i == index) 18.dp else 6.dp, 6.dp).clip(RoundedCornerShape(50)).background(if (i == index) Tokens.text else Color(0x55FFFFFF))) }
        }
    }
}
