package app.streamsetu.tv.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

/** The slideshow at the top of Home: "DISCOVER · FROM YOUR LIBRARY", a title, and a coral Play pill. Changes every few seconds; a new mix every launch. */
@Composable
fun FeaturedBanner(items: List<Playable>, onOpen: (Playable) -> Unit, modifier: Modifier = Modifier) {
    if (items.isEmpty()) return
    var index by remember(items) { mutableIntStateOf(0) }
    LaunchedEffect(items) { while (true) { delay(7000); index = (index + 1) % items.size } }
    val item = items[index.coerceIn(0, items.lastIndex)]
    val shape = RoundedCornerShape(Tokens.radiusLarge)
    Box(modifier.fillMaxWidth().height(168.dp).clip(shape).background(Tokens.card)) {
        Crossfade(item, label = "banner") { it ->
            Box(Modifier.fillMaxSize()) {
                PosterPlaceholder(it.title, Modifier.fillMaxSize())
                if (!it.artworkUrl.isNullOrBlank()) AsyncImage(it.artworkUrl, it.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.TopCenter)
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Color(0xE60B0D12), Color(0x990B0D12), Color.Transparent))))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xB30B0D12)))))
        Column(Modifier.align(Alignment.BottomStart).padding(18.dp).widthIn(max = 480.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Eyebrow("DISCOVER · FROM YOUR LIBRARY", color = Tokens.accent)
            Label(item.title, Tokens.display, Tokens.text, FontWeight.SemiBold, maxLines = 2)
            Label(if (item is SeriesFeature) "Series" else "Movie", Tokens.small, Tokens.textSecondary)
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                TvButton(if (item is SeriesFeature) "Open" else "Play", { onOpen(item) }, icon = Icons.Filled.PlayArrow, primary = true)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items.indices.forEach { i -> Box(Modifier.size(if (i == index) 18.dp else 7.dp, 7.dp).clip(RoundedCornerShape(50)).background(if (i == index) Tokens.text else Color(0x55FFFFFF))) }
                }
            }
        }
    }
}
