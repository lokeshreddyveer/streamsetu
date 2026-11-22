package app.streamsetu.tv.ui.screens.library

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.InfiniteTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

// The moving art of the start and setup screens, all drawn in code. Everything here is still when motion is reduced (the app's setting or Android's animator scale at 0) and then shows
// its final state. Draw work is kept small for a Fire TV Stick: brushes, strokes and paths are made once per size (drawWithCache) and only moved while drawing, a light that sweeps
// now and then holds still between sweeps (so nothing is redrawn while it waits), and the slow backdrop drift is redrawn about 30 times a second rather than on every frame.

private const val TAU = (2 * PI).toFloat()

/** 0 at both ends and 1 in the middle of [p] in 0..1: an out-and-back movement. */
internal fun bump(p: Float): Float = sin(PI.toFloat() * p.coerceIn(0f, 1f))

/** A value that runs from 0 to 1 over [sweepMs] and then rests at 1 until [periodMs] is over, again and again. It does not change while it rests, so nothing is redrawn then. */
@Composable
private fun InfiniteTransition.sweep(sweepMs: Int, periodMs: Int, label: String): State<Float> =
    animateFloat(0f, 1f, infiniteRepeatable(keyframes { durationMillis = periodMs; 0f at 0 using LinearEasing; 1f at sweepMs; 1f at periodMs }), label = label)

/**
 * Rings of fading [color] just outside the shape being drawn: a soft glow, with no blur layer. [amount] 0..1 fades it; [stroke] and [ring] (the spacing of the rings) are made once by
 * the caller.
 */
internal fun DrawScope.softGlow(color: Color, amount: Float, cornerPx: Float, stroke: Stroke, ring: Float, rings: Int = 6) {
    if (amount < 0.01f) return
    for (i in 1..rings) {
        val out = i * ring
        drawRoundRect(color.copy(alpha = 0.12f * amount * (1f - i / (rings + 1f))), Offset(-out, -out), Size(size.width + 2 * out, size.height + 2 * out), CornerRadius(cornerPx + out), style = stroke)
    }
}

/**
 * The backdrop as a slow aurora: the page colour, a soft glow in the look's glow colour near [anchor] (fractions of the page) and a fainter second one towards the opposite top corner,
 * both drifting on long loops (24 s and 30 s), a faint ribbon of light crossing the page every 8 s, and a gentle vignette. The opacities are so low that text contrast does not change.
 * Drawn in its own layer, behind the page, so its redraws never touch the page itself.
 */
@Composable
internal fun StartBackground(anchor: Offset, modifier: Modifier = Modifier) {
    val look = LocalStartLook.current
    val reduced = reducedMotion()
    val clock = if (reduced) null else rememberInfiniteTransition(label = "aurora")
    val a = clock?.animateFloat(0f, 1f, infiniteRepeatable(tween(24_000, easing = LinearEasing)), label = "driftA")
    val b = clock?.animateFloat(0f, 1f, infiniteRepeatable(tween(30_000, easing = LinearEasing)), label = "driftB")
    val streak = clock?.sweep(2600, 8000, "streak")
    // The drift is slow, so it is redrawn in 720 steps per loop (about 30 a second) instead of on every frame.
    val qa = remember(a) { derivedStateOf { a?.let { (it.value * 720).toInt() } ?: 0 } }
    val qb = remember(b) { derivedStateOf { b?.let { (it.value * 900).toInt() } ?: 0 } }
    Box(modifier.fillMaxSize().graphicsLayer().drawWithCache {
        val short = size.minDimension; val r = short * 0.55f; val r2 = short * 0.7f
        val g1 = look.glow; val g2 = look.glow2
        val glowBrush = Brush.radialGradient(0f to g1.copy(alpha = 0.18f), 0.5f to g1.copy(alpha = 0.08f), 1f to Color.Transparent, center = Offset.Zero, radius = r)
        val glow2Brush = Brush.radialGradient(0f to g2.copy(alpha = 0.07f), 0.5f to g2.copy(alpha = 0.03f), 1f to Color.Transparent, center = Offset.Zero, radius = r2)
        val vignette = Brush.radialGradient(0.55f to Color.Transparent, 1f to Color(0x66000000), center = Offset(size.width / 2, size.height / 2), radius = size.maxDimension * 0.75f)
        val band = size.width * 0.32f
        val ribbon = Brush.horizontalGradient(0f to Color.Transparent, 0.45f to g1.copy(alpha = 0.035f), 0.5f to Color.White.copy(alpha = 0.03f), 0.55f to g1.copy(alpha = 0.035f), 1f to Color.Transparent, startX = 0f, endX = band)
        val far = Offset(if (anchor.x < 0.5f) size.width * 0.94f else size.width * 0.06f, 0f)
        onDrawBehind {
            drawRect(look.base)
            val ta = qa.value / 720f * TAU; val tb = qb.value / 900f * TAU
            translate(size.width * anchor.x + cos(ta) * short * 0.07f, size.height * anchor.y + sin(ta) * short * 0.045f) { drawCircle(glowBrush, r, Offset.Zero) }
            translate(far.x + sin(tb) * short * 0.09f, far.y + cos(tb) * short * 0.05f) { drawCircle(glow2Brush, r2, Offset.Zero) }
            val s = streak?.value ?: 1f
            val slack = size.height * 0.35f          // the tilt, so the ribbon starts and ends fully off the page
            if (s < 1f) rotate(-16f, pivot = center) { translate(-band - slack + (size.width + 2 * (band + slack)) * s, 0f) { drawRect(ribbon, Offset(0f, -size.height * 0.5f), Size(band, size.height * 2f)) } }
            if (look.vignette) drawRect(vignette)
        }
    })
}

/** The brand symbol, floating gently (3 dp up and down over 6 s) with a soft light passing over it every 7 s, masked to the symbol itself. */
@Composable
internal fun FloatingSymbol(size: Dp, modifier: Modifier = Modifier) {
    val reduced = reducedMotion()
    val clock = if (reduced) null else rememberInfiniteTransition(label = "symbol")
    val float = clock?.animateFloat(0f, 1f, infiniteRepeatable(tween(6000, easing = LinearEasing)), label = "float")
    val sheen = clock?.sweep(1400, 7000, "sheen")
    Image(painterResource(app.streamsetu.tv.R.drawable.brand_symbol), null,
        modifier.size(size)
            .graphicsLayer { translationY = float?.let { sin(it.value * TAU) * 3.dp.toPx() } ?: 0f; compositingStrategy = CompositingStrategy.Offscreen; clip = true }          // the light never leaves the symbol's own square
            .drawWithCache {
                val w = this.size.width * 0.3f
                val light = Brush.horizontalGradient(0f to Color.Transparent, 0.5f to Color.White.copy(alpha = 0.42f), 1f to Color.Transparent, startX = 0f, endX = w)
                onDrawWithContent {
                    drawContent()
                    val p = sheen?.value ?: 1f
                    // The band is tilted, so it starts and ends far enough out (by the tilt over the height) that no part of it lies over the symbol at either end.
                    val slack = this.size.height * 0.4f
                    if (p < 1f) rotate(18f, pivot = center) { translate(-w - slack + (this.size.width + 2 * (w + slack)) * p, 0f) { drawRect(light, Offset(0f, -this.size.height * 0.5f), Size(w, this.size.height * 2f), blendMode = BlendMode.SrcAtop) } }
                }
            })
}

/** Teal for the tile art: the icons keep the brand's own colour in every theme. */
private val IconTeal = Color(0xFF3CC6D6)

/**
 * A connection kind's icon, drawn as vector shapes in a rounded square with a soft teal-to-clear fill. Still at rest; it plays its little animation once when it first appears (after
 * [appearDelayMs]) and again each time [play] changes (focus or press). A kind with no tile of its own shows [fallback] instead.
 */
@Composable
internal fun TileIcon(tile: ConnectTile?, size: Dp, modifier: Modifier = Modifier, play: Int = 0, appearDelayMs: Long = 0, fallback: ImageVector? = null) {
    val reduced = reducedMotion()
    val p = remember { Animatable(1f) }
    LaunchedEffect(play) {
        if (reduced || tile == null) return@LaunchedEffect
        if (play == 0) delay(appearDelayMs)
        p.snapTo(0f); p.animateTo(1f, tween(if (tile == ConnectTile.TUNER) 1300 else 900, easing = LinearEasing))
    }
    val shape = RoundedCornerShape(size * 0.28f)
    Box(modifier.size(size).clip(shape).background(Brush.linearGradient(listOf(IconTeal.copy(alpha = 0.30f), IconTeal.copy(alpha = 0.04f)))).border(1.dp, IconTeal.copy(alpha = 0.25f), shape), Alignment.Center) {
        if (tile == null) { if (fallback != null) Image(fallback, null, Modifier.size(size * 0.5f), colorFilter = ColorFilter.tint(IconTeal)); return@Box }
        Spacer(Modifier.size(size * 0.58f).drawWithCache {
            val u = this.size.minDimension
            val line = Stroke(u * 0.085f, cap = StrokeCap.Round, join = StrokeJoin.Round)
            val thin = Stroke(u * 0.06f, cap = StrokeCap.Round, join = StrokeJoin.Round)
            val path = Path()
            onDrawBehind { drawTileArt(tile, p.value, u, line, thin, path) }
        })
    }
}

/** One frame of a tile's art at animation progress [p] (1 = at rest). Only shapes and the one reused [path]; nothing is allocated. */
private fun DrawScope.drawTileArt(tile: ConnectTile, p: Float, u: Float, line: Stroke, thin: Stroke, path: Path) {
    val c = IconTeal
    val moving = p < 1f
    when (tile) {
        // Two chain links that pull apart a little, slide back together and click (a small pulse).
        ConnectTile.PLAYLIST_LINK -> {
            val apart = bump(p / 0.7f) * u * 0.09f
            val click = if (p > 0.7f) 1f + 0.1f * bump((p - 0.7f) / 0.3f) else 1f
            scale(click) {
                val w = u * 0.52f; val h = u * 0.32f; val y = u * 0.5f - h / 2
                drawRoundRect(c, Offset(u * 0.04f - apart, y), Size(w, h), CornerRadius(h / 2), style = line)
                drawRoundRect(c, Offset(u * 0.44f + apart, y), Size(w, h), CornerRadius(h / 2), style = line)
            }
        }
        // A server rack whose three lights blink on in turn.
        ConnectTile.XTREAM -> for (i in 0..2) {
            val y = u * (0.06f + i * 0.31f); val h = u * 0.25f
            drawRoundRect(c, Offset(u * 0.06f, y), Size(u * 0.88f, h), CornerRadius(h * 0.3f), style = thin)
            val lit = if (moving) 0.25f + 0.75f * bump((p - i * 0.22f) / 0.45f) else 1f
            drawCircle(c.copy(alpha = lit), u * 0.05f, Offset(u * 0.24f, y + h / 2))
            drawLine(c.copy(alpha = 0.6f), Offset(u * 0.5f, y + h / 2), Offset(u * 0.78f, y + h / 2), strokeWidth = thin.width, cap = StrokeCap.Round)
        }
        // A play triangle that pulses inside two stacked frames.
        ConnectTile.MEDIA_SERVER -> {
            drawRoundRect(c.copy(alpha = 0.55f), Offset(u * 0.26f, u * 0.08f), Size(u * 0.68f, u * 0.52f), CornerRadius(u * 0.08f), style = thin)
            drawRoundRect(c, Offset(u * 0.06f, u * 0.3f), Size(u * 0.68f, u * 0.56f), CornerRadius(u * 0.08f), style = line)
            val k = 1f + 0.28f * bump(p); val cx = u * 0.41f; val cy = u * 0.58f; val s = u * 0.13f * k
            path.rewind(); path.moveTo(cx - s * 0.8f, cy - s); path.lineTo(cx + s, cy); path.lineTo(cx - s * 0.8f, cy + s); path.close()
            drawPath(path, c, style = Fill)
        }
        // An antenna whose radio waves ripple outwards.
        ConnectTile.TUNER -> {
            val top = Offset(u * 0.5f, u * 0.42f)
            drawLine(c, Offset(u * 0.5f, u * 0.5f), Offset(u * 0.5f, u * 0.94f), strokeWidth = line.width, cap = StrokeCap.Round)
            drawLine(c, Offset(u * 0.34f, u * 0.94f), Offset(u * 0.66f, u * 0.94f), strokeWidth = line.width, cap = StrokeCap.Round)
            drawCircle(c, u * 0.07f, top)
            for (i in 0..1) {
                val q = if (moving) ((p * 2f + i * 0.5f) % 1f) else i * 0.5f + 0.25f
                val r = u * (0.16f + 0.26f * q); val a = if (moving) (1f - q) else 1f - i * 0.35f
                val box = Size(r * 2, r * 2); val at = Offset(top.x - r, top.y - r)
                drawArc(c.copy(alpha = a), 150f, 60f, false, at, box, style = thin)
                drawArc(c.copy(alpha = a), -30f, 60f, false, at, box, style = thin)
            }
        }
        // A folder whose front lid opens a little.
        ConnectTile.FILES -> {
            path.rewind()
            path.moveTo(u * 0.06f, u * 0.84f); path.lineTo(u * 0.06f, u * 0.16f); path.lineTo(u * 0.38f, u * 0.16f); path.lineTo(u * 0.46f, u * 0.26f); path.lineTo(u * 0.94f, u * 0.26f); path.lineTo(u * 0.94f, u * 0.84f); path.close()
            drawPath(path, c, style = thin)
            val open = bump(p)
            val ytop = u * (0.4f + 0.1f * open); val skew = u * 0.08f * open
            path.rewind(); path.moveTo(u * 0.06f + skew, ytop); path.lineTo(u * 0.94f + skew, ytop); path.lineTo(u * 0.94f, u * 0.84f); path.lineTo(u * 0.06f, u * 0.84f); path.close()
            drawPath(path, c.copy(alpha = 0.35f), style = Fill)
            drawPath(path, c, style = line)
        }
        // A set-top box with a status light that blinks.
        ConnectTile.STALKER -> {
            drawRoundRect(c, Offset(u * 0.06f, u * 0.34f), Size(u * 0.88f, u * 0.38f), CornerRadius(u * 0.08f), style = line)
            drawLine(c, Offset(u * 0.2f, u * 0.53f), Offset(u * 0.52f, u * 0.53f), strokeWidth = thin.width, cap = StrokeCap.Round)
            drawLine(c, Offset(u * 0.2f, u * 0.82f), Offset(u * 0.3f, u * 0.82f), strokeWidth = line.width, cap = StrokeCap.Round)
            drawLine(c, Offset(u * 0.7f, u * 0.82f), Offset(u * 0.8f, u * 0.82f), strokeWidth = line.width, cap = StrokeCap.Round)
            val on = !moving || ((p * 6f).toInt() % 2 == 0)
            drawCircle(c.copy(alpha = if (on) 1f else 0.2f), u * 0.055f, Offset(u * 0.78f, u * 0.53f))
        }
    }
}

/** Three dots in a soft wave, for "Connecting…". With reduced motion the label carries a plain ellipsis instead. */
@Composable
internal fun DotWave(color: Color, dot: Dp = 5.dp, modifier: Modifier = Modifier) {
    val clock = rememberInfiniteTransition(label = "dots")
    val t = clock.animateFloat(0f, 1f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "wave")
    Spacer(modifier.size(dot * 5, dot * 2.4f).drawWithCache {
        val r = dot.toPx() / 2
        onDrawBehind { for (i in 0..2) { val ph = (t.value - i * 0.16f + 1f) % 1f; val lift = bump(ph / 0.5f); drawCircle(color.copy(alpha = 0.45f + 0.55f * lift), r, Offset(r + i * r * 4f, size.height - r - lift * r * 1.6f)) } }
    })
}

/** The success mark: a filled disc grows in, a ring bursts outwards in [ring], and the check draws its own stroke. Static and complete with reduced motion. */
@Composable
internal fun AnimatedCheck(size: Dp, fill: Color, ring: Color, modifier: Modifier = Modifier) {
    val reduced = reducedMotion()
    val p = remember { Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(Unit) { if (!reduced) p.animateTo(1f, tween(1100, easing = LinearEasing)) }
    Spacer(modifier.size(size * 1.6f).drawWithCache {
        val r = size.toPx() / 2; val cx = this.size.width / 2; val cy = this.size.height / 2
        val check = Path().apply { moveTo(cx - r * 0.42f, cy + r * 0.02f); lineTo(cx - r * 0.12f, cy + r * 0.32f); lineTo(cx + r * 0.45f, cy - r * 0.3f) }
        val measure = PathMeasure().apply { setPath(check, false) }
        val part = Path()
        val tick = Stroke(r * 0.16f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val burst = Stroke(r * 0.08f)
        onDrawBehind {
            val v = p.value
            val disc = (v / 0.35f).coerceIn(0f, 1f); val grow = 1f - (1f - disc) * (1f - disc)
            if (v in 0.15f..0.95f) { val q = (v - 0.15f) / 0.8f; drawCircle(ring.copy(alpha = (1f - q) * 0.7f), r * (1f + 0.6f * q), center, style = burst) }
            drawCircle(fill, r * grow, center)
            val draw = ((v - 0.3f) / 0.45f).coerceIn(0f, 1f)
            if (draw > 0f) { part.rewind(); measure.getSegment(0f, measure.length * draw, part, true); drawPath(part, Color.White, style = tick) }
        }
    })
}
