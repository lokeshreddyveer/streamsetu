package app.streamsetu.core.ui.motion

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Every duration, curve, scale, distance and elevation the app animates with, in one place. Screens never write their own numbers.
 * The values are kept modest on purpose: a Fire TV Stick has a small GPU, so motion is transforms and alpha only (no blur, no layout changes).
 */
object Motion {
    // ---- Durations (ms) ----
    const val FOCUS = 160                 // a card or button taking focus
    const val SHORT = 200                 // chips, badges, small reveals
    const val CONTROLS = 180              // player controls in and out
    const val SIDEBAR = 260               // sidebar widening or narrowing
    const val SCREEN = 300                // moving between screens
    const val DETAIL = 320                // poster to fullscreen detail
    const val BANNER = 800                // featured slideshow crossfade (700 to 900)
    const val HIGHLIGHT = 180             // the folder highlight sliding to the next row

    // ---- Curves ----
    /** Quick start, soft landing: the default for anything that moves. */
    val Standard: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    /** Leaving: starts slowly and goes. */
    val Exit: Easing = CubicBezierEasing(0.4f, 0f, 1f, 1f)

    // ---- Focus ----
    const val POSTER_FOCUS_SCALE = 1.04f
    const val CARD_FOCUS_SCALE = 1.03f
    const val ROW_FOCUS_SCALE = 1.0f      // list rows do not grow; a highlight moves behind them
    val FOCUS_ELEVATION: Dp = 8.dp

    // ---- Distances ----
    val RISE: Dp = 14.dp                  // a page or panel rising into place
    val SLIDE: Dp = 24.dp                 // a panel sliding in from its edge

    /** Opacity of content that is present but not the focus of attention. */
    const val DIMMED = 0.55f
}

/** True when the person turned animations off in Android's settings (Developer options / Accessibility "Remove animations"). */
@Composable
fun rememberReducedMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) { reducedMotion(context) }
}

fun reducedMotion(context: Context): Boolean = runCatching {
    val r = context.contentResolver
    Settings.Global.getFloat(r, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f ||
        Settings.Global.getFloat(r, Settings.Global.TRANSITION_ANIMATION_SCALE, 1f) == 0f
}.getOrDefault(false)

val LocalReducedMotion = compositionLocalOf { false }

/** A tween that becomes an instant change when reduced motion is on. */
@Composable
fun <T> motionSpec(durationMs: Int = Motion.SCREEN, easing: Easing = Motion.Standard): FiniteAnimationSpec<T> =
    if (LocalReducedMotion.current) snap() else tween(durationMs, easing = easing)

/**
 * Scales [Modifier] with focus. Reads the animated value inside graphicsLayer, so a focus change redraws one layer and never re-measures or re-composes the card.
 * Rapid D-pad movement retargets the running animation instead of queueing one per card.
 */
@Composable
fun Modifier.focusScale(focused: Boolean, scale: Float = Motion.POSTER_FOCUS_SCALE): Modifier {
    val reduced = LocalReducedMotion.current
    // A critically damped spring: no bounce, and a new target mid-animation continues from the current value and speed, so rapid D-pad moves never queue or jump.
    val s = animateFloatAsState(if (focused) scale else 1f, if (reduced) snap() else spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 900f), label = "focusScale")
    return graphicsLayer { scaleX = s.value; scaleY = s.value }
}

/** Fades and lifts content into place when [visible] becomes true (and back). Alpha and translation only. */
@Composable
fun Modifier.fadeRise(visible: Boolean, durationMs: Int = Motion.SCREEN, distance: Dp = Motion.RISE): Modifier {
    val reduced = LocalReducedMotion.current
    val a = animateFloatAsState(if (visible) 1f else 0f, if (reduced) snap() else tween(durationMs, easing = Motion.Standard), label = "fadeRise")
    return graphicsLayer {
        alpha = a.value
        translationY = (1f - a.value) * distance.toPx()
    }
}

/** For content that must stay laid out (so focus is not lost) while it is hidden: only its opacity and position change. */
@Composable
fun Modifier.slideFade(visible: Boolean, fromX: Dp = 0.dp, fromY: Dp = 0.dp, durationMs: Int = Motion.CONTROLS): Modifier {
    val reduced = LocalReducedMotion.current
    val a = animateFloatAsState(if (visible) 1f else 0f, if (reduced) snap() else tween(durationMs, easing = if (visible) Motion.Standard else Motion.Exit), label = "slideFade")
    return graphicsLayer {
        alpha = a.value
        translationX = (1f - a.value) * fromX.toPx()
        translationY = (1f - a.value) * fromY.toPx()
    }
}

/** Dims content that sits behind something else without removing it. */
@Composable
fun Modifier.dimmed(dim: Boolean): Modifier {
    val reduced = LocalReducedMotion.current
    val a = animateFloatAsState(if (dim) Motion.DIMMED else 1f, if (reduced) snap() else tween(Motion.SHORT), label = "dim")
    return alpha(a.value)
}
