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
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.lifecycle.repeatOnLifecycle
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
    paused: Boolean = false,
    isFavorite: (BannerItem) -> Boolean = { false },
    onToggleFavorite: ((BannerItem) -> Unit)? = null,
    eyebrow: String = "FEATURED",
) {
    if (items.isEmpty()) return
    val reduced = LocalReducedMotion.current
    var index by remember(items.firstOrNull()?.id, items.size) { mutableIntStateOf(0) }
    // The slideshow keeps going while the remote simply rests on a button; it waits only while the person is pressing keys on the banner.
    var lastKey by remember { mutableLongStateOf(0L) }
    val n = items.size
    val i = index.coerceIn(0, n - 1)
    val item = items[i]
    val context = LocalContext.current

    // Rotate every few seconds, unless a key was pressed on the banner in the last 8 seconds. Reduced motion keeps the rotation but drops the fade (the picture just changes).
    val pausedNow by rememberUpdatedState(paused)
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(items, intervalSeconds) {
        if (n < 2) return@LaunchedEffect
        // The loop runs only while the app is on screen: it stops in the background and starts again on return.
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while (true) { delay(intervalSeconds * 1000L); if (!pausedNow && System.currentTimeMillis() - lastKey > 8000) index = (index + 1) % n }
        }
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
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Tokens.background.copy(alpha = 0.97f), 0.42f to Tokens.background.copy(alpha = 0.72f), 0.8f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Tokens.background)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Tokens.background.copy(alpha = 0.55f), 0.22f to Color.Transparent)))

        Column(Modifier.align(Alignment.BottomStart).padding(start = startPadding, bottom = 22.dp).widthIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.background(Tokens.accent.copy(alpha = 0.16f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(6.dp).background(Tokens.accent, RoundedCornerShape(50)))
                Label(eyebrow, Tokens.eyebrow, Tokens.accent, FontWeight.Bold, letterSpacing = 1.2.sp)
            }
            AnimatedContent(i, transitionSpec = { fadeIn(tween(if (reduced) 0 else Motion.BANNER)) togetherWith fadeOut(tween(if (reduced) 0 else Motion.BANNER)) }, label = "bannerText") { idx ->
                val it = items[idx.coerceIn(0, n - 1)]
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(it.title, 36.sp, Tokens.text, FontWeight.ExtraBold, maxLines = 2)
                    if (it.facts.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        it.facts.forEach { fact -> Label(fact, Tokens.small, Tokens.text, FontWeight.Medium, modifier = Modifier.background(Color(0x26FFFFFF), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 3.dp)) }
                    }
                    if (!it.synopsis.isNullOrBlank()) Label(it.synopsis, Tokens.body, Tokens.textSecondary, maxLines = 3)
                }
            }
            Row(Modifier.padding(top = 4.dp).onPreviewKeyEvent { lastKey = System.currentTimeMillis(); false }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton(item.primaryLabel, { onPrimary(item) }, if (primaryEntry != null) Modifier.focusRequester(primaryEntry) else Modifier, icon = Icons.Filled.PlayArrow, primary = true)
                TvButton("Details", { onDetails(item) }, icon = Icons.Filled.Info)
                val listed = isListed(item)
                TvButton(if (listed) "Remove" else listedLabel, { onToggleListed(item) }, icon = if (listed) Icons.Filled.Check else Icons.Filled.Add)
                if (onToggleFavorite != null) { val fav = isFavorite(item); TvButton(if (fav) "Favorited" else "Favorite", { onToggleFavorite(item) }, icon = if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder) }
            }
        }
        if (n > 1) Row(Modifier.align(Alignment.BottomEnd).padding(end = Tokens.screenPadding, bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            repeat(n) { d -> Box(Modifier.size(width = if (d == i) 26.dp else 8.dp, height = 4.dp).background(if (d == i) Tokens.accent else Tokens.text.copy(alpha = 0.3f), RoundedCornerShape(50))) }
        }
    }
}
