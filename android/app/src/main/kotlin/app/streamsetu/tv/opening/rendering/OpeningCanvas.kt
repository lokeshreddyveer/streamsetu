package app.streamsetu.tv.opening.rendering

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.res.imageResource
import app.streamsetu.tv.opening.domain.OpeningMotionState
import androidx.compose.ui.graphics.StrokeJoin

/** What the canvas draws besides the frame: how far the exit is (0..1) and whether it is the match-cut (the screen opens to the frame) or a plain fade. */
class OpeningExtras(val exit: Float, val matchCut: Boolean, val time: Float)

/** The layers of the artwork (motion/assets/tune-in, the 512 px copies: light enough for a Fire TV Stick, and sharp at the mark's size), decoded once. */
class TuneInLayers(val ribbonRear: ImageBitmap, val screen: ImageBitmap, val antennaLeft: ImageBitmap, val antennaRight: ImageBitmap, val body: ImageBitmap,
                   val play: ImageBitmap, val ribbonFront: ImageBitmap, val sweepMask: ImageBitmap, val glintMask: ImageBitmap)

@Composable
private fun rememberLayers(): TuneInLayers {
    @Composable fun img(id: Int) = ImageBitmap.imageResource(id)
    return TuneInLayers(img(app.streamsetu.tv.R.drawable.opening_ribbon_rear), img(app.streamsetu.tv.R.drawable.opening_screen), img(app.streamsetu.tv.R.drawable.opening_antenna_left),
        img(app.streamsetu.tv.R.drawable.opening_antenna_right), img(app.streamsetu.tv.R.drawable.opening_tv_body), img(app.streamsetu.tv.R.drawable.opening_play_button),
        img(app.streamsetu.tv.R.drawable.opening_ribbon_front), img(app.streamsetu.tv.R.drawable.opening_sweep_mask), img(app.streamsetu.tv.R.drawable.opening_glint_mask))
}

/**
 * Draws one frame of "Tune In" from [frame] (read while drawing, so a new frame redraws and recomposes nothing). The 1000 x 600 artboard is fitted into the view and centred;
 * on a portrait screen only its middle 700 units are fitted, so the mark stays large. The television is the supplied artwork in its layers, never redrawn or distorted: only
 * moved (the camera push, the antennas' small turn about their pivots, the play button growing from its centre) and uncovered (the ribbon drawn on along its centre-line).
 * Everything that does not change is made once per size. [lightweight] is the plain look of the same story for weak devices: no grain, no snow, no light on the silver, and
 * the ribbon fades in instead of drawing on. [frame] returning null draws the plain background (the plan is not known yet).
 */
@Composable
fun OpeningCanvas(frame: () -> OpeningMotionState?, extras: () -> OpeningExtras, lightweight: () -> Boolean, modifier: Modifier = Modifier) {
    val layers = rememberLayers()
    val measurer = rememberTextMeasurer()
    val geo = remember { TuneInGeometry() }
    val grain = remember { noiseTile(128, 9, 0.06f) }
    val snow = remember { noiseTile(96, 31, 0.55f) }
    Spacer(modifier.drawWithCache {
        val window = if (size.width < size.height) 700f else 1000f
        val s = minOf(size.width / window, size.height / 600f)
        val ox = size.width / 2f - 500f * s; val oy = size.height / 2f - 300f * s
        val b = Brushes(geo, grain, snow)
        val px = 1f / s
        val name = measurer.measure("StreamSetu", TextStyle(color = OpeningColors.foreground, fontSize = (56f / density / fontScale).sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.8f / density / fontScale).sp))
        val tagline = measurer.measure("Your streams. One home.", TextStyle(color = OpeningColors.foregroundSecondary, fontSize = (24f / density / fontScale).sp, fontWeight = FontWeight.Medium))
        val tools = Tools(Paint(), Stroke(geo.rearReveal, cap = StrokeCap.Round, join = StrokeJoin.Round), Stroke(geo.frontReveal, cap = StrokeCap.Round, join = StrokeJoin.Round))
        onDrawBehind {
            drawRect(OpeningColors.background)
            val f = frame() ?: return@onDrawBehind
            val e = extras(); val light = lightweight()
            withTransform({ translate(ox, oy); scale(s, s, Offset.Zero) }) {
                // The room: a teal glow behind the set as it rises out of the dark.
                translate(geo.markCenter.x, geo.markCenter.y + 20f) { drawCircle(b.room, 420f, Offset.Zero, alpha = f.roomGlow) }
                withTransform({ scale(f.camera, f.camera, geo.markCenter); translate(geo.mark.left, geo.mark.top); scale(geo.k, geo.k, Offset.Zero) }) {
                    drawTelevision(geo, f, layers, b, tools, light)
                }
                // The words: the name settles from a little wider (2-4 % tracking) as it fades up; the tagline fades in beneath it.
                if (f.name > 0f) withTransform({ scale(1f + 0.035f * f.nameTracking, 1f, Offset(500f, geo.nameBaseline)) }) {
                    translate(500f - name.size.width / 2f, geo.nameBaseline - name.firstBaseline) { drawText(name, alpha = f.name) }
                }
                if (f.tagline > 0f) translate(500f - tagline.size.width / 2f, geo.taglineBaseline - tagline.firstBaseline) { drawText(tagline, alpha = f.tagline) }
                // The match-cut: the teal screen opens out to the whole frame (the layer itself then fades into the app underneath).
                if (e.matchCut && e.exit > 0f) {
                    val t = app.streamsetu.tv.opening.domain.Easing.cubicInOut((e.exit / 0.6f).coerceAtMost(1f))
                    val scr = geo.windowOnArtboard
                    val l = lerp(scr.left, -ox * px - 20f, t); val tp = lerp(scr.top, -oy * px - 20f, t)
                    val r = lerp(scr.right, (size.width - ox) * px + 20f, t); val bt = lerp(scr.bottom, (size.height - oy) * px + 20f, t)
                    drawRoundRect(OpeningColors.matchCut, Offset(l, tp), Size(r - l, bt - tp), androidx.compose.ui.geometry.CornerRadius(40f * (1f - t)), alpha = (t * 1.6f).coerceAtMost(1f))
                }
            }
            // Fine grain over everything, very faint.
            if (!light) drawRect(b.grainBrush, alpha = 0.5f)
        }
    })
}

private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t

/** Paints and strokes made once per size. */
private class Tools(val layer: Paint, val rearReveal: Stroke, val frontReveal: Stroke)

/** Brushes and tiles of the opening, made once: those that move are made around (0, 0) and only moved. */
private class Brushes(g: TuneInGeometry, grain: ImageBitmap, snow: ImageBitmap) {
    val room = Brush.radialGradient(listOf(OpeningColors.backgroundGlow, OpeningColors.backgroundGlow.copy(alpha = 0.4f), Color.Transparent), center = Offset.Zero, radius = 420f)
    val screenWarm = Brush.radialGradient(listOf(OpeningColors.teal.copy(alpha = 0.55f), OpeningColors.teal.copy(alpha = 0.12f), Color.Transparent), center = g.window.center, radius = g.window.width * 0.7f)
    val behindPlay = Brush.radialGradient(0f to Color(0xFF021A24), 0.6f to Color(0xFF021A24).copy(alpha = 0.85f), 1f to Color.Transparent, center = g.play, radius = 190f)
    val dot = Brush.radialGradient(listOf(Color.White, OpeningColors.cream, OpeningColors.cream.copy(alpha = 0.35f), Color.Transparent), center = Offset.Zero, radius = 54f)
    val sweep = Brush.linearGradient(0f to Color.Transparent, 0.5f to Color(0xFFFFF4E6).copy(alpha = 0.6f), 1f to Color.Transparent, start = Offset(0f, 0f), end = Offset(220f, 0f))
    val sheen = Brush.linearGradient(0f to Color.Transparent, 0.5f to OpeningColors.iceTeal.copy(alpha = 0.75f), 1f to Color.Transparent, start = Offset(0f, 0f), end = Offset(300f, 0f))
    val grainBrush = ShaderBrush(ImageShader(grain, TileMode.Repeated, TileMode.Repeated))
    val snowBrush = ShaderBrush(ImageShader(snow, TileMode.Repeated, TileMode.Repeated))
}

private fun DrawScope.full(img: ImageBitmap, alpha: Float = 1f, blendMode: BlendMode = BlendMode.SrcOver) =
    drawImage(img, IntOffset.Zero, IntSize(img.width, img.height), IntOffset.Zero, IntSize(TuneInGeometry.CANVAS.toInt(), TuneInGeometry.CANVAS.toInt()), alpha = alpha, blendMode = blendMode)

/**
 * The television, in the artwork's z-order (ribbon behind, screen, antennas, body, play button, ribbon in front), on its 1024 canvas. All of it is drawn into one layer that
 * fades in as a whole as the set rises out of the dark. The weak spots of the cut-out artwork stay covered: the glass behind the play button is dark until the button has
 * grown over it, and the glass and frame under the front ribbon are only seen while the ribbon draws on.
 */
private fun DrawScope.drawTelevision(g: TuneInGeometry, f: OpeningMotionState, l: TuneInLayers, b: Brushes, t: Tools, light: Boolean) {
    val dotAlpha = f.dot * (1f - f.swell)
    val drawDot: DrawScope.() -> Unit = { if (dotAlpha > 0.01f) translate(g.play.x, g.play.y) { drawCircle(b.dot, 54f * (0.6f + 0.4f * f.dot) * (1f + 0.8f * f.swell), Offset.Zero, alpha = dotAlpha) } }
    if (f.set <= 0.003f) { drawDot(); return }
    t.layer.alpha = f.set
    drawIntoCanvas { it.saveLayer(g.canvas, t.layer) }

    ribbon(l.ribbonRear, f.ribbonRear, g.rearMeasure, g.trimmedRear, t.rearReveal, light)

    // The screen: its glass, dark at first, faint snow while it tunes, then warming to teal; the glass behind the play button stays dark until the button covers it.
    clipPath(g.windowPath) {
        full(l.screen)
        val off = (1f - f.warm) * 0.92f
        if (off > 0.01f) drawRect(Color(0xFF02070A), g.window.topLeft, g.window.size, alpha = off)
        if (f.snow > 0.001f && !light) {
            val step = ((f.snow * 997f).toInt() % 7) * 37f
            translate(step, step * 0.7f) { drawRect(b.snowBrush, Offset(g.window.left - 300f, g.window.top - 300f), Size(g.window.width + 600f, g.window.height + 600f), alpha = f.snow) }
        }
        if (f.warm > 0f && f.warm < 1f) drawRect(b.screenWarm, g.window.topLeft, g.window.size, alpha = kotlin.math.sin(Math.PI.toFloat() * f.warm))
        if (f.swell < 1f) drawCircle(b.behindPlay, 190f, g.play, alpha = 1f - f.swell * f.swell)
    }

    // The antennas tune: a small turn about their pivots and a settle.
    val turn = g.maxTwitchDeg * 0.7f * f.twitch
    rotate(-turn, g.antennaLeftPivot) { full(l.antennaLeft) }
    rotate(turn, g.antennaRightPivot) { full(l.antennaRight) }
    full(l.body)

    // The play button grows from the dot at its centre, then gives its small press-in at the hero.
    if (f.swell > 0f) {
        val k = (0.12f + 0.88f * f.swell) * (1f - 0.025f * f.press)
        scale(k, k, g.play) { full(l.play, alpha = (f.swell * 2.5f).coerceAtMost(1f)) }
    }

    ribbon(l.ribbonFront, f.ribbonFront, g.frontMeasure, g.trimmedFront, t.frontReveal, light, sheen = if (light) -1f else f.sheen, b = b)

    // The light on the silver: a sweep across the body and antennas, kept to the silver by its mask; then one glint on the right antenna's ball.
    if (!light && f.sweep >= 0f) {
        drawIntoCanvas { it.saveLayer(g.canvas, Paint()) }
        rotate(-22f, g.canvas.center) { translate(-300f + 1600f * f.sweep, -200f) { drawRect(b.sweep, Offset.Zero, Size(220f, 1500f)) } }
        full(l.sweepMask, blendMode = BlendMode.DstIn)
        drawIntoCanvas { it.restore() }
    }
    if (!light && f.glint > 0.01f) clipRect(g.glintArea.left, g.glintArea.top, g.glintArea.right, g.glintArea.bottom) { full(l.glintMask, alpha = f.glint, blendMode = BlendMode.Plus) }

    drawIntoCanvas { it.restore() }
    drawDot()
}

/**
 * One part of the ribbon. Drawing on: the band is uncovered along its centre-line by a wide round stroke, so its edges stay the artwork's own; at the end it is simply drawn.
 * [sheen] (0..1, negative for none) is a satin light travelling along it, kept to the ribbon's own pixels. In the plain look it fades in instead.
 */
private fun DrawScope.ribbon(img: ImageBitmap, progress: Float, m: PathMeasure, trimmed: Path, reveal: Stroke, light: Boolean, sheen: Float = -1f, b: Brushes? = null) {
    if (progress <= 0.001f) return
    if (light) { full(img, alpha = progress); return }
    val layered = progress < 0.999f || (sheen >= 0f && b != null)
    if (!layered) { full(img); return }
    drawIntoCanvas { it.saveLayer(Rect(0f, 0f, TuneInGeometry.CANVAS, TuneInGeometry.CANVAS), Paint()) }
    full(img)
    if (progress < 0.999f) {
        trimmed.rewind(); m.getSegment(0f, m.length * progress, trimmed, true)
        drawPath(trimmed, Color.White, style = reveal, blendMode = BlendMode.DstIn)
    }
    if (sheen >= 0f && b != null) translate(-300f + 1400f * sheen, 0f) { drawRect(b.sheen, Offset(0f, 300f), Size(300f, 700f), blendMode = BlendMode.SrcAtop) }
    drawIntoCanvas { it.restore() }
}

/** A small square of grey noise, made once: the grain over the frame and the snow on the screen. [alpha] is the strongest speck. */
private fun noiseTile(n: Int, seed: Int, alpha: Float): ImageBitmap {
    val bmp = android.graphics.Bitmap.createBitmap(n, n, android.graphics.Bitmap.Config.ARGB_8888)
    val r = java.util.Random(seed.toLong())
    val px = IntArray(n * n) { val v = r.nextInt(256); val a = (r.nextFloat() * alpha * 255).toInt(); (a shl 24) or (v shl 16) or (v shl 8) or v }
    bmp.setPixels(px, 0, n, 0, 0, n, n)
    return bmp.asImageBitmap()
}
