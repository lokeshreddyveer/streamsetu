package app.streamsetu.tv.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.delay

/** One slide of a featured banner. Everything shown comes from the catalog or the provider; nothing is made up. */
data class BannerItem(
    val id: String,
    val title: String,
    /** Genre, year, runtime or season count: only the parts that exist. */
    val facts: List<String>,
    val synopsis: String?,
    val imageUrl: String?,
    val primaryLabel: String,
    val progress: Float = 0f,
)

/**
 * The featured slideshow of Home, Movies and Series.
 * Slides change about every 9 seconds with a long crossfade, and the next picture is loaded ahead of time. The slideshow stands still while the remote is on
 * a button, and for a while after; it never starts video; with reduced motion on it does not rotate. Only the picture and the text change: the buttons are
 * never replaced, so the remote's focus cannot be lost when a slide changes.
 */
@Composable
fun FeaturedBanner(
    items: List<BannerItem>,
    height: Dp,
    onPrimary: (BannerItem) -> Unit,
    onDetails: (BannerItem) -> Unit,
    isListed: (BannerItem) -> Boolean,
    onToggleListed: (BannerItem) -> Unit,
    listedLabel: String = "Watch Later",
    modifier: Modifier = Modifier,
    primaryEntry: FocusRequester? = null,
    startPadding: Dp = Tokens.screenPadding,
    intervalSeconds: Int = 9,
) {
    if (items.isEmpty()) return
    val reduced = LocalReducedMotion.current
    var index by remember(items.firstOrNull()?.id, items.size) { mutableIntStateOf(0) }
    var focusInside by remember { mutableStateOf(false) }
    var lastFocusChange by remember { mutableLongStateOf(0L) }
    val n = items.size
    val i = index.coerceIn(0, n - 1)
    val item = items[i]
    val context = LocalContext.current

    // Rotate every ~9 s unless the remote is on the banner (or just left it).
    val paused by rememberUpdatedState(focusInside || System.currentTimeMillis() - lastFocusChange < 6000)
    LaunchedEffect(items, reduced) {
        if (reduced || n < 2) return@LaunchedEffect
        while (true) { delay(intervalSeconds * 1000L); if (!paused) index = (index + 1) % n }
    }
    // The next slide's picture is requested now, so the crossfade never waits on the network.
    LaunchedEffect(i, items) {
        items.getOrNull((i + 1) % n)?.imageUrl?.takeIf { it.isNotBlank() }?.let { url ->
            coil.Coil.imageLoader(context).enqueue(ImageRequest.Builder(context).data(url).build())
        }
    }

    Box(modifier.fillMaxWidth().height(height)) {
        Crossfade(i, Modifier.fillMaxSize(), animationSpec = if (reduced) tween(0) else tween(Motion.BANNER), label = "bannerImage") { idx ->
            val it = items[idx.coerceIn(0, n - 1)]
            Box(Modifier.fillMaxSize()) {
                PosterPlaceholder(it.title, Modifier.fillMaxSize())
                if (!it.imageUrl.isNullOrBlank()) AsyncImage(it.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        // Dark left to right for the text, and a fade into the page below.
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Tokens.background.copy(alpha = 0.96f), Tokens.background.copy(alpha = 0.55f), Color.Transparent))))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Tokens.background.copy(alpha = 0.9f)), startY = height.value * 1.6f)))

        Column(Modifier.align(Alignment.BottomStart).padding(start = startPadding, bottom = 14.dp).widthIn(max = 420.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            AnimatedContent(i, transitionSpec = { fadeIn(tween(if (reduced) 0 else Motion.BANNER)) togetherWith fadeOut(tween(if (reduced) 0 else Motion.BANNER)) }, label = "bannerText") { idx ->
                val it = items[idx.coerceIn(0, n - 1)]
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Label(it.title, Tokens.display, Tokens.text, FontWeight.Bold, maxLines = 2)
                    if (it.facts.isNotEmpty()) Label(it.facts.joinToString("  ·  "), Tokens.small, Tokens.textSecondary)
                    if (!it.synopsis.isNullOrBlank()) Label(it.synopsis, Tokens.body, Tokens.textSecondary, maxLines = 3)
                }
            }
            Row(Modifier.padding(top = 4.dp).onFocusChanged { focusInside = it.hasFocus; lastFocusChange = System.currentTimeMillis() }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton(item.primaryLabel, { onPrimary(item) }, if (primaryEntry != null) Modifier.focusRequester(primaryEntry) else Modifier, icon = Icons.Filled.PlayArrow, primary = true)
                TvButton("Details", { onDetails(item) }, icon = Icons.Filled.Info)
                val listed = isListed(item)
                TvButton(if (listed) "Remove" else listedLabel, { onToggleListed(item) }, icon = if (listed) Icons.Filled.Check else Icons.Filled.Add)
            }
        }
        if (n > 1) Row(Modifier.align(Alignment.BottomEnd).padding(end = Tokens.screenPadding, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            repeat(n) { d -> Box(Modifier.size(width = if (d == i) 16.dp else 5.dp, height = 5.dp).background(if (d == i) Tokens.text else Tokens.text.copy(alpha = 0.35f), RoundedCornerShape(50))) }
        }
    }
}
