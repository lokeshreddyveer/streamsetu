package app.streamsetu.tv.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.screens.library.reducedMotion
import app.streamsetu.tv.ui.theme.Tokens
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

// The app's own motion pieces, used across the screens: the brand loader (the television's dot breathing, with a thin ribbon of light circling it), a soft light passing over
// placeholders while content loads, and small drawn pictures for empty pages. Every colour comes from the chosen theme and accent; every loop runs only while it is on screen
// (Compose stops it when it leaves the screen or the app goes to the background), and with reduced motion each is still.

/**
 * The brand loader: the dot of the StreamSetu television breathing, with a thin arc of the accent circling it. For full-page and section loads; a small spinner inside a row
 * or a button may stay as it is.
 */
@Composable
fun BrandLoader(modifier: Modifier = Modifier, size: Dp = 40.dp, color: Color = Tokens.accent) {
    val reduced = reducedMotion()
    val clock = if (reduced) null else rememberInfiniteTransition(label = "brandLoader")
    val turn = clock?.animateFloat(0f, 1f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "turn")
    val breath = clock?.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing)), label = "breath")
    Spacer(modifier.size(size).drawWithCache {
        val r = this.size.minDimension / 2
        val ring = Stroke(r * 0.1f, cap = StrokeCap.Round)
        val glow = Brush.radialGradient(listOf(color.copy(alpha = 0.45f), Color.Transparent), center = Offset(this.size.width / 2, this.size.height / 2), radius = r * 0.7f)
        onDrawBehind {
            val b = breath?.let { 0.5f - 0.5f * cos(it.value * 2 * PI.toFloat()) } ?: 0.6f
            drawCircle(glow, r * 0.7f, center, alpha = 0.5f + 0.5f * b)
            drawCircle(Color.White, r * (0.16f + 0.05f * b), center, alpha = 0.9f)
            drawCircle(color.copy(alpha = 0.16f), r * 0.82f, center, style = ring)
            val start = (turn?.value ?: 0.1f) * 360f
            drawArc(color, start, 90f + 40f * b, false, Offset(center.x - r * 0.82f, center.y - r * 0.82f), Size(r * 1.64f, r * 1.64f), style = ring)
        }
    })
}

/** A soft band of light passing over a placeholder while its content loads (drawn over it). Still with reduced motion. */
@Composable
fun Modifier.shimmer(): Modifier {
    val reduced = reducedMotion()
    val t = if (reduced) null else rememberInfiniteTransition(label = "shimmer").animateFloat(0f, 1f, infiniteRepeatable(tween(1300, easing = LinearEasing)), label = "shimmerT")
    return this.drawWithCache {
        val band = size.width * 0.45f
        val light = Brush.horizontalGradient(0f to Color.Transparent, 0.5f to Color.White.copy(alpha = 0.07f), 1f to Color.Transparent, startX = 0f, endX = band)
        onDrawWithContent {
            drawContent()
            val p = t?.value ?: return@onDrawWithContent
            translate(-band + (size.width + band) * p, 0f) { drawRect(light, Offset.Zero, Size(band, size.height)) }
        }
    }
}

/** What an empty page is about, which decides its small picture. */
enum class EmptyArt { NoResults, Nothing, Bookmark, NoConnection, Error, Library }

/**
 * An empty page: a small drawn picture that moves a little (a magnifier sweeping, the television tuning, a bookmark settling, a ribbon coiling), a title and one line.
 * The picture plays once when the page appears and then holds still.
 */
@Composable
fun AnimatedEmptyState(art: EmptyArt, title: String, message: String, modifier: Modifier = Modifier, titleSize: TextUnit = Tokens.title, messageSize: TextUnit = Tokens.body, artSize: Dp = 72.dp) {
    val reduced = reducedMotion()
    val p = remember { androidx.compose.animation.core.Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(Unit) { if (!reduced) p.animateTo(1f, tween(1400, easing = app.streamsetu.core.ui.motion.Motion.Standard)) }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val accent = Tokens.accent; val line = Tokens.textSecondary
        Spacer(Modifier.size(artSize).drawWithCache {
            val u = size.minDimension
            val s = Stroke(u * 0.055f, cap = StrokeCap.Round)
            onDrawBehind { drawEmptyArt(art, p.value, u, s, accent, line) }
        })
        Label(title, titleSize, Tokens.text, FontWeight.SemiBold, maxLines = 2, textAlign = TextAlign.Center)
        Label(message, messageSize, Tokens.textSecondary, maxLines = 3, textAlign = TextAlign.Center)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawEmptyArt(art: EmptyArt, p: Float, u: Float, s: Stroke, accent: Color, line: Color) {
    val settle = 1f - (1f - p) * (1f - p)
    when (art) {
        // A magnifier that sweeps once across and settles.
        EmptyArt.NoResults -> {
            val x = u * (0.42f + 0.12f * sin(p * PI.toFloat() * 2f) * (1f - p))
            drawCircle(line, u * 0.22f, Offset(x, u * 0.42f), style = s)
            drawLine(accent, Offset(x + u * 0.16f, u * 0.58f), Offset(x + u * 0.34f, u * 0.78f), strokeWidth = s.width * 1.4f, cap = StrokeCap.Round)
        }
        // A television tuning: faint snow settling into a single dot.
        EmptyArt.Nothing, EmptyArt.Library -> {
            drawRoundRect(line, Offset(u * 0.12f, u * 0.26f), Size(u * 0.76f, u * 0.54f), androidx.compose.ui.geometry.CornerRadius(u * 0.1f), style = s)
            drawLine(line, Offset(u * 0.38f, u * 0.08f), Offset(u * 0.48f, u * 0.24f), strokeWidth = s.width, cap = StrokeCap.Round)
            drawLine(line, Offset(u * 0.64f, u * 0.08f), Offset(u * 0.54f, u * 0.24f), strokeWidth = s.width, cap = StrokeCap.Round)
            val snow = (1f - settle)
            if (snow > 0.02f) for (i in 0 until 14) {
                val fx = ((i * 37) % 100) / 100f; val fy = ((i * 61) % 100) / 100f
                drawCircle(line.copy(alpha = 0.6f * snow), u * 0.012f, Offset(u * (0.2f + 0.6f * fx), u * (0.32f + 0.42f * fy)))
            }
            drawCircle(accent, u * 0.05f * settle, Offset(u * 0.5f, u * 0.53f))
            if (art == EmptyArt.Library) drawArc(accent, 160f, 220f * settle, false, Offset(u * 0.06f, u * 0.5f), Size(u * 0.88f, u * 0.36f), style = s)
        }
        // A bookmark that drops in and settles.
        EmptyArt.Bookmark -> {
            val y = -u * 0.2f * (1f - settle)
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(u * 0.3f, u * 0.14f + y); lineTo(u * 0.7f, u * 0.14f + y); lineTo(u * 0.7f, u * 0.86f + y); lineTo(u * 0.5f, u * 0.68f + y); lineTo(u * 0.3f, u * 0.86f + y); close()
            }
            drawPath(path, accent.copy(alpha = 0.18f))
            drawPath(path, accent, style = s)
        }
        // A broken link: two halves that drift apart a little.
        EmptyArt.NoConnection -> {
            val gap = u * 0.06f * settle
            drawRoundRect(line, Offset(u * 0.1f - gap, u * 0.38f), Size(u * 0.42f, u * 0.24f), androidx.compose.ui.geometry.CornerRadius(u * 0.12f), style = s)
            drawRoundRect(accent, Offset(u * 0.48f + gap, u * 0.38f), Size(u * 0.42f, u * 0.24f), androidx.compose.ui.geometry.CornerRadius(u * 0.12f), style = s)
        }
        // A ribbon coiling into a ring, with a mark in the middle.
        EmptyArt.Error -> {
            drawArc(accent, -90f, 330f * settle, false, Offset(u * 0.16f, u * 0.16f), Size(u * 0.68f, u * 0.68f), style = s)
            drawLine(line, Offset(u * 0.5f, u * 0.32f), Offset(u * 0.5f, u * 0.54f), strokeWidth = s.width, cap = StrokeCap.Round)
            drawCircle(line, s.width * 0.7f, Offset(u * 0.5f, u * 0.66f))
        }
    }
}

/**
 * The first-appearance stagger: rows and cards that appear together come in one after another, 35 ms apart and never more than six steps (so a long list is not held back),
 * and each key only the first time in a session. Pure and clock-driven, so it can be tested.
 */
class StaggerLimiter(private val now: () -> Long = { android.os.SystemClock.uptimeMillis() }) {
    private val seen = HashSet<String>()
    private var burstStart = Long.MIN_VALUE
    private var inBurst = 0
    /** The delay for [key], or null when it has appeared before (then it is simply there). */
    fun delayFor(key: String): Long? {
        if (!seen.add(key)) return null
        val t = now()
        if (burstStart == Long.MIN_VALUE || t - burstStart > BURST_MS) { burstStart = t; inBurst = 0 }
        return STEP_MS * minOf(inBurst++, MAX_STEPS)
    }
    companion object { const val STEP_MS = 35L; const val MAX_STEPS = 6; const val BURST_MS = 400L }
}

/** The app's one stagger, for the whole session. */
val AppStagger = StaggerLimiter()

/** A row or card rising a little into place and fading in, the first time [key] appears in a session (see [StaggerLimiter]). With reduced motion it only appears. */
@Composable
fun Modifier.staggerIn(key: String): Modifier {
    val reduced = reducedMotion()
    val wait = remember(key) { if (reduced) null else AppStagger.delayFor(key) }
    val a = remember(key) { androidx.compose.animation.core.Animatable(if (wait == null) 1f else 0f) }
    LaunchedEffect(key) { if (wait != null) { kotlinx.coroutines.delay(wait); a.animateTo(1f, tween(380, easing = app.streamsetu.core.ui.motion.Motion.Standard)) } }
    return if (wait == null) this else this.graphicsLayer { alpha = a.value; translationY = (1f - a.value) * 10.dp.toPx() }
}

/** A progress bar's fill that grows to its value the first time it is shown (Continue Watching), drawn without measuring anything again. Still with reduced motion. */
@Composable
fun Modifier.progressFill(progress: Float, track: Color, fill: Color): Modifier {
    val reduced = reducedMotion()
    val shown = remember { androidx.compose.animation.core.Animatable(if (reduced) progress else 0f) }
    LaunchedEffect(progress) { if (reduced) shown.snapTo(progress) else shown.animateTo(progress, tween(650, easing = app.streamsetu.core.ui.motion.Motion.Standard)) }
    return this.drawBehind { drawRect(track); drawRect(fill, size = Size(size.width * shown.value.coerceIn(0f, 1f), size.height)) }
}

/** A slow drift into the picture (3 % over 9 s) for a featured picture, once per [key] while it is shown; moving only a layer, nothing is drawn again. None with reduced motion. */
@Composable
fun Modifier.kenBurns(key: Any): Modifier {
    if (reducedMotion()) return this
    val k = remember(key) { androidx.compose.animation.core.Animatable(1f) }
    LaunchedEffect(key) { k.animateTo(1.03f, tween(9000, easing = LinearEasing)) }
    return this.graphicsLayer { scaleX = k.value; scaleY = k.value }
}
