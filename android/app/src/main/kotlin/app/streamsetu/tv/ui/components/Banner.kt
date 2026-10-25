package app.streamsetu.tv.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.snap
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
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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

/** Text for a runtime and a rating as the provider gives them ("01:55:36", "6.796"): a person reads "1 h 55 min" and "6.8". */
object Facts {
    fun runtime(raw: String?): String? {
        val t = raw?.trim()?.takeIf { it.isNotBlank() } ?: return null
        val parts = t.split(':').mapNotNull { it.toIntOrNull() }
        val minutes = when {
            t.contains(':') && parts.size == 3 -> parts[0] * 60 + parts[1] + if (parts[2] >= 30) 1 else 0
            t.contains(':') && parts.size == 2 -> parts[0] * 60 + parts[1]
            else -> t.toIntOrNull() ?: return t
        }
        if (minutes <= 0) return null
        return if (minutes >= 60) "${minutes / 60} h" + (if (minutes % 60 != 0) " ${minutes % 60} min" else "") else "$minutes min"
    }
    fun rating(raw: String?): String? = raw?.toDoubleOrNull()?.takeIf { it > 0 }?.let { "★ %.1f".format(it) }
}

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
    /** False when the only picture is a portrait poster: it is then shown as a poster, at its own shape, not stretched across the whole banner. */
    val imageIsBackdrop: Boolean = true,
)

/**
 * The featured slideshow of Home, Movies and Series.
 * Slides change about every 9 seconds with a long crossfade, and the next picture is loaded ahead of time. The slideshow stands still while the remote is on
 * a button, and for a while after; it never starts video; with reduced motion on it does not rotate. Only the picture and the text change: the buttons are
 * never replaced, so the remote's focus cannot be lost when a slide changes.
 */
@Composable
fun FeaturedBanner(
    candidates: List<BannerItem>,
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
    /** Drawn over the top of the banner (the page header), above a soft shade that keeps it readable on any picture. */
    topOverlay: (@Composable BoxScope.() -> Unit)? = null,
) {
    // A slide with no picture at all is left out of the rotation (an empty tint is not a hero); if none has one, they are all kept.
    val items = remember(candidates) { candidates.filter { !it.imageUrl.isNullOrBlank() }.ifEmpty { candidates } }
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
                Box(Modifier.fillMaxSize().background(Tokens.card))
                if (!it.imageUrl.isNullOrBlank()) {
                    if (it.imageIsBackdrop) {
                        // The subject of a wide picture is usually in the upper middle: crop from there, so faces are not cut off.
                        AsyncImage(it.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = BiasAlignment(0f, -0.45f))
                    } else {
                        // Only a portrait poster exists: it is shown at its own shape on the right, over a calm tint of the title's colour, never blown up to fill the banner.
                        Box(Modifier.fillMaxSize().background(Tokens.background.copy(alpha = 0.55f)))
                        AsyncImage(it.imageUrl, null, Modifier.align(Alignment.CenterEnd).padding(top = 72.dp, bottom = 30.dp, end = 150.dp).fillMaxHeight().aspectRatio(2f / 3f, matchHeightConstraintsFirst = true).clip(RoundedCornerShape(Tokens.radius)), contentScale = ContentScale.Crop)
                    }
                }
            }
        }
        // One shade for the text on the left, one for the page header on top, and the bottom edge melts into the page.
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Tokens.background.copy(alpha = 0.92f), 0.5f to Tokens.background.copy(alpha = 0.4f), 0.85f to Color.Transparent)))
        if (topOverlay != null) Box(Modifier.fillMaxWidth().height(120.dp).background(Brush.verticalGradient(0f to Tokens.background.copy(alpha = 0.75f), 1f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.62f to Color.Transparent, 1f to Tokens.background)))

        // Title, facts, story and the buttons sit at the bottom left; the column is sized so it never reaches the page header.
        Column(Modifier.align(Alignment.BottomStart).padding(start = startPadding, bottom = 30.dp).widthIn(max = 600.dp).heightIn(max = height - 64.dp), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.Bottom)) {
            AnimatedContent(i, contentAlignment = Alignment.BottomStart, transitionSpec = { fadeIn(tween(if (reduced) 0 else Motion.BANNER)) togetherWith fadeOut(tween(if (reduced) 0 else Motion.BANNER)) using SizeTransform(clip = false) { _, _ -> snap() } }, label = "bannerText") { idx ->
                val it = items[idx.coerceIn(0, n - 1)]
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(it.title, 40.sp, Tokens.text, FontWeight.Bold, maxLines = 2)
                    if (it.facts.isNotEmpty()) Label(it.facts.joinToString("   ·   "), Tokens.small, Tokens.textSecondary, FontWeight.Medium, maxLines = 1)
                    if (!it.synopsis.isNullOrBlank()) Label(it.synopsis, Tokens.small, Tokens.textSecondary, maxLines = 2)
                }
            }
            Row(Modifier.railOnLeft().padding(top = 6.dp).onPreviewKeyEvent { lastKey = System.currentTimeMillis(); false }, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton(item.primaryLabel, { onPrimary(item) }, if (primaryEntry != null) Modifier.focusRequester(primaryEntry) else Modifier, icon = Icons.Filled.PlayArrow, primary = true)
                TvButton("More Info", { onDetails(item) }, icon = Icons.Filled.Info)
                val listed = isListed(item)
                TvButton(if (listed) "In $listedLabel" else listedLabel, { onToggleListed(item) }, icon = if (listed) Icons.Filled.Check else Icons.Filled.Add)
            }
        }
        topOverlay?.invoke(this)
        if (n > 1) Row(Modifier.align(Alignment.BottomEnd).padding(end = Tokens.safeHorizontal, bottom = 18.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            repeat(n) { d -> Box(Modifier.size(width = if (d == i) 18.dp else 6.dp, height = 3.dp).background(if (d == i) Color.White else Tokens.text.copy(alpha = 0.3f), RoundedCornerShape(2.dp))) }
        }
    }
}
