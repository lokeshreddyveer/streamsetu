package app.streamsetu.tv.ui.components

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.smartmix.ShelfView
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.tv.ui.i18n.I18n
import app.streamsetu.tv.ui.phone.Ph
import app.streamsetu.tv.ui.theme.Tokens

/** "Ranking for <shelf title>", the label of the control as a group. */
fun rankingGroupLabel(shelfTitle: String) = I18n.tr("Ranking for $shelfTitle")

/** The one short line under a ranking shelf's title (at most 20 characters): what the shelf is ordered by right now. [ordered] = a TMDB list ordered it. */
fun shelfSubtitle(view: ShelfView, ordered: Boolean): String = when {
    view == ShelfView.WEEKLY && ordered -> "Trending this week"
    view == ShelfView.WEEKLY -> "Popular here"
    ordered -> "Best of all time"
    else -> "Highest rated here"
}

/** True when animations are off: the person's Reduce Motion, or the system animator scale set to 0. */
@Composable
private fun animationsOff(): Boolean {
    if (LocalReducedMotion.current) return true
    val ctx = LocalContext.current
    return remember { runCatching { android.provider.Settings.Global.getFloat(ctx.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false) }
}

/**
 * The small two-option control "All time | This week": equal-width segments in a thin track, a selection indicator that slides (instantly when animations are off), a light haptic when the choice
 * changes, 48 dp touch targets inside a control that is drawn about 32 dp high, TalkBack names ("All time top", "Trending this week") with the selected state, one container "Ranking for <title>".
 * On a television both segments are focusable with a focus ring on the segment; [down] is where Down goes (the first tile of the same shelf). Focus stays on the control while the shelf swaps.
 */
@Composable
fun ShelfViewSwitch(shelfTitle: String, view: ShelfView, tv: Boolean, onView: (ShelfView) -> Unit, modifier: Modifier = Modifier, down: FocusRequester? = null) {
    val scale = LocalDensity.current.fontScale.coerceIn(1f, 2f)
    val segW: Dp = (68.dp * scale)
    val off = animationsOff()
    val haptic = LocalHapticFeedback.current
    val x by animateDpAsState(if (view == ShelfView.ALL_TIME) 0.dp else segW, if (off) snap() else tween(280), label = "shelfIndicator")
    val shape = RoundedCornerShape(50)
    val select: (ShelfView) -> Unit = { v -> if (v != view) { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); onView(v) } }
    Box(modifier.width(segW * 2 + 4.dp).height(48.dp).semantics { contentDescription = rankingGroupLabel(shelfTitle) }) {
        Box(Modifier.align(Alignment.Center).fillMaxWidth().height(32.dp).background(Tokens.text.copy(alpha = 0.08f), shape))
        Box(Modifier.align(Alignment.CenterStart).offset(x = 2.dp + x).width(segW).height(28.dp).background(Tokens.accent.copy(alpha = 0.30f), shape).border(1.dp, Tokens.accent, shape).testTag("switch-indicator"))
        Row(Modifier.fillMaxSize().padding(horizontal = 2.dp)) {
            for ((v, label, spoken, tag) in listOf(Quad(ShelfView.ALL_TIME, "All time", "All time top", "chip-all-time"), Quad(ShelfView.WEEKLY, "This week", "Trending this week", "chip-weekly"))) {
                val on = view == v
                val sem = Modifier.width(segW).fillMaxHeight().testTag(tag).semantics(mergeDescendants = true) { contentDescription = I18n.tr(spoken); role = Role.RadioButton; selected = on }
                val text: @Composable () -> Unit = { Label(label, if (tv) Tokens.small else 13.sp, Tokens.text, if (on) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1) }
                if (tv) Focusable({ select(v) }, sem.then(if (down != null) Modifier.focusProperties { this.down = down } else Modifier), shape = shape, container = androidx.compose.ui.graphics.Color.Transparent,
                    focusedContainer = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.18f), scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = true, ringBand = false) { _ -> Box(Modifier.fillMaxSize(), Alignment.Center) { text() } }
                else Box(sem.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.RadioButton) { select(v) }, Alignment.Center) { text() }
            }
        }
    }
}

private data class Quad(val a: ShelfView, val b: String, val c: String, val d: String)
private operator fun Quad.component1() = a
private operator fun Quad.component2() = b
private operator fun Quad.component3() = c
private operator fun Quad.component4() = d

/**
 * The one header of Trending in Your Library and every genre shelf. Row 1: the title (heading, up to two lines) and "See all ›" for a genre shelf. Row 2 (at least 30 dp high, the same in both
 * views): the subtitle at the left and the switch at the right; at a large font the switch drops under the subtitle, nothing truncates. [firstTile] is where Down goes on a television.
 */
@Composable
fun ShelfHeader(title: String, subtitle: String?, view: ShelfView?, tv: Boolean, onView: (ShelfView) -> Unit, onSeeAll: (() -> Unit)?, modifier: Modifier = Modifier, firstTile: FocusRequester? = null) {
    val stack = LocalDensity.current.fontScale >= 1.5f
    val start = if (tv) Tokens.safeHorizontal else Ph.gutter
    Column(modifier.fillMaxWidth().padding(start = start, end = if (tv) Tokens.safeHorizontal else Ph.gutter)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Label(title, if (tv) Tokens.title else 20.sp, Tokens.text, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.weight(1f).semantics { heading() })
            if (onSeeAll != null) {
                if (tv) Focusable(onSeeAll, Modifier.testTag("see-all").then(if (firstTile != null) Modifier.focusProperties { down = firstTile } else Modifier), shape = RoundedCornerShape(50), container = androidx.compose.ui.graphics.Color.Transparent, focusedContainer = androidx.compose.ui.graphics.Color.White, scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = false, ringBand = false) { f ->
                    Label("See all ›", Tokens.small, if (f) Tokens.onBright else Tokens.accent, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
                } else Box(Modifier.heightIn(min = 48.dp).testTag("see-all").clickable(role = Role.Button, onClick = onSeeAll).padding(start = 8.dp), Alignment.CenterEnd) { Label("See all ›", Ph.small, Tokens.accent, FontWeight.Medium, maxLines = 1) }
            }
        }
        if (view != null) {
            val sub: @Composable () -> Unit = { if (subtitle != null) Label(subtitle, if (tv) Tokens.small else Ph.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.testTag("shelf-subtitle")) }
            val sw: @Composable () -> Unit = { ShelfViewSwitch(title, view, tv, onView, down = firstTile) }
            if (stack) Column(Modifier.heightIn(min = 30.dp)) { sub(); sw() }
            else Row(Modifier.fillMaxWidth().heightIn(min = 30.dp), verticalAlignment = Alignment.CenterVertically) { Box(Modifier.weight(1f)) { sub() }; sw() }
        }
    }
}
