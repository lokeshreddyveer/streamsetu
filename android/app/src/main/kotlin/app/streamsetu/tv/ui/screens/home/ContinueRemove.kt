package app.streamsetu.tv.ui.screens.home

import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Undo
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.tv.ui.components.ContextMenu
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.MenuAction
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.screens.library.reducedMotion
import app.streamsetu.tv.ui.theme.Tokens

// Removing titles from Continue Watching: the same actions on every screen (the menu's "Remove from Continue Watching" and "Mark as watched", and "Clear Continue Watching…" on
// the Continue Watching page), a bar that offers Undo for a few seconds, cards that leave and come back with a spring, and a screen-reader action on every card.

/** The TalkBack action on a Continue Watching card, so removing does not depend on finding the long press. */
fun Modifier.removeFromContinueAction(onRemove: () -> Unit): Modifier = this.semantics {
    customActions = listOf(CustomAccessibilityAction("Remove from Continue Watching") { onRemove(); true })
}

/** A card leaving or joining the row: it fades, and the row closes (or opens) the gap with a spring. With reduced motion it only fades. */
@Composable
fun LazyItemScope.continueItemMotion(): Modifier {
    val reduced = reducedMotion()
    return Modifier.animateItem(
        fadeInSpec = tween(180), fadeOutSpec = tween(160),
        placementSpec = if (reduced) null else spring(dampingRatio = 0.82f, stiffness = 385f, visibilityThreshold = IntOffset(1, 1)),
    )
}

/**
 * The hint under the Continue Watching row on a television, shown the first time the row has the remote in a session, and no more once the person has used the menu there.
 * The rows only read and set it.
 */
object ContinueHint {
    var used by mutableStateOf(false)
    var shownThisSession by mutableStateOf(false)
}

@Composable
fun ContinueHintLine(rowHasFocus: Boolean) {
    var showing by remember { mutableStateOf(false) }
    LaunchedEffect(rowHasFocus) {
        if (rowHasFocus && !ContinueHint.used && !ContinueHint.shownThisSession) showing = true
        else if (!rowHasFocus && showing) { showing = false; ContinueHint.shownThisSession = true }
    }
    if (showing && !ContinueHint.used) Label("Hold OK for options", Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(start = Tokens.safeHorizontal, top = 2.dp))
}

/**
 * The Undo bar after a removal: "Removed from Continue Watching" and Undo, for about five seconds. It rises into place; on a phone the removal is felt as a light tick and the
 * Undo as a confirm. On a television the remote moves to Undo while the bar is up (OK undoes; moving away or waiting lets it go).
 */
@Composable
fun ContinueUndoBar(vm: HomeViewModel, tv: Boolean, modifier: Modifier = Modifier) {
    val undo by vm.continueUndo.collectAsStateWithLifecycle()
    val u = undo ?: return
    val view = LocalView.current
    val reduced = reducedMotion()
    val enter = remember(u.stamp) { Animatable(if (reduced) 1f else 0f) }
    val undoFocus = remember { FocusRequester() }
    LaunchedEffect(u.stamp) {
        if (!tv) view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        else app.streamsetu.tv.ui.components.requestFocusSoon(undoFocus, 8)
        if (!reduced) enter.animateTo(1f, spring(dampingRatio = 0.82f, stiffness = 385f))
    }
    val doUndo = {
        if (!tv && android.os.Build.VERSION.SDK_INT >= 30) view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        vm.undoContinue(); Unit
    }
    Row(
        modifier.padding(16.dp).widthIn(max = 560.dp)
            .graphicsLayer { alpha = enter.value; translationY = (1f - enter.value) * 24.dp.toPx() }
            .background(Tokens.elevated, RoundedCornerShape(16.dp)).border(1.dp, Tokens.lineStrong, RoundedCornerShape(16.dp))
            .padding(start = 18.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Label(u.message, if (tv) Tokens.body else 14.sp, Tokens.text, FontWeight.Medium, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
        if (tv) TvButton("Undo", doUndo, Modifier.focusRequester(undoFocus), icon = Icons.Filled.Undo, primary = true)
        else app.streamsetu.tv.ui.screens.library.PhonePill("Undo", doUndo, icon = Icons.Filled.Undo)
    }
}

/** "Clear Continue Watching…": asks first, then empties the row (with Undo). */
@Composable
fun ClearContinueConfirm(vm: HomeViewModel, onClose: () -> Unit) {
    ContextMenu("Clear Continue Watching?", "Every title leaves the row. Watched marks and history stay. You can undo for a few seconds.", listOf(
        MenuAction("Clear Continue Watching", Icons.Filled.DeleteSweep, danger = true) { vm.clearContinue() },
        MenuAction("Keep them", Icons.Filled.Check) { },
    ), onClose = onClose)
}
