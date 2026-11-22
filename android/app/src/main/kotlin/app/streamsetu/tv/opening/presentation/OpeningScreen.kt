package app.streamsetu.tv.opening.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.opening.domain.OpeningTimeline
import app.streamsetu.tv.opening.domain.OpeningVariant
import app.streamsetu.tv.opening.rendering.OpeningCanvas
import app.streamsetu.tv.opening.rendering.OpeningExtras
import app.streamsetu.tv.opening.rendering.OpeningColors
import app.streamsetu.tv.opening.startup.StartupCoordinator
import app.streamsetu.tv.opening.startup.StartupState
import app.streamsetu.tv.ui.components.Label

private const val DESCRIPTION = "StreamSetu. A television in a dark room is tuned in: a dot on its screen becomes the play button, and a teal ribbon wraps around the set."

/**
 * The opening layer, over the app (which is already built underneath and becomes visible as this fades). It draws what the coordinator says and hands it the frame clock;
 * it owns no time of its own, so being rebuilt never restarts it, and it ends on elapsed time alone. Gone from the tree once the opening has completed. It cannot be skipped:
 * taps and Back are ignored while it plays (Back never leaves the app here). A failed start-up shows a short recovery panel instead of leaving the person stuck.
 */
@Composable
fun OpeningLayer(phone: Boolean) {
    val c = StartupCoordinator
    if (!c.visible) return
    // The frame clock: only while this is on screen and the app is in front (no frames are delivered in the background), and only until the opening completes.
    LaunchedEffect(Unit) { while (c.visible) withFrameNanos { c.onFrame(it) } }
    if (phone) BackHandler(enabled = c.state != StartupState.FAILED) { /* ignored while the opening plays */ }
    Box(
        Modifier.fillMaxSize()
            // The match-cut opens the teal screen to the whole frame first, then the layer gives way to the app underneath; the reduced-motion still simply fades.
            .graphicsLayer { alpha = if (c.plan?.variant == OpeningVariant.REDUCED) 1f - c.exitProgress else 1f - ((c.exitProgress - 0.5f) / 0.5f).coerceIn(0f, 1f) }
            // Touches are kept from the app underneath while the opening plays; they do nothing.
            .pointerInput(Unit) { detectTapGestures { } }
            .semantics { contentDescription = DESCRIPTION },
    ) {
        OpeningCanvas({ c.plan?.variant?.let { OpeningTimeline.state(it, c.elapsedMs) } },
            { OpeningExtras(c.exitProgress, matchCut = c.plan?.variant != OpeningVariant.REDUCED, time = c.elapsedMs) }, { c.lightweight }, Modifier.fillMaxSize())
        if (c.state == StartupState.FAILED) RecoveryPanel(phone, Modifier.align(Alignment.Center))
    }
}

/** Shown when the app's start-up failed: what happened, Try again, and Continue (the app opens anyway and reads the library again later). */
@Composable
private fun RecoveryPanel(phone: Boolean, modifier: Modifier) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { if (!phone) app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    // The remote stays inside the panel: the app underneath cannot take it while the panel is up.
    Column(modifier.widthIn(max = 460.dp).padding(24.dp).focusProperties { exit = { FocusRequester.Cancel } }
        .background(Color(0xE60B1630), RoundedCornerShape(20.dp)).border(1.dp, Color(0x1AFFFFFF), RoundedCornerShape(20.dp)).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Label("StreamSetu could not finish starting", 20.sp, OpeningColors.foreground, FontWeight.Bold, maxLines = 2, textAlign = TextAlign.Center)
        Label("Your library could not be read just now. Try again, or continue and it will be read again in the app.", 15.sp, Color(0xFFB7C1CE), maxLines = 4, textAlign = TextAlign.Center)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            app.streamsetu.tv.ui.screens.library.PrimaryAction("Try again", { StartupCoordinator.retry() }, Modifier.focusRequester(first))
            app.streamsetu.tv.ui.screens.library.QuietAction("Continue", { StartupCoordinator.continueAnyway() })
        }
    }
}
