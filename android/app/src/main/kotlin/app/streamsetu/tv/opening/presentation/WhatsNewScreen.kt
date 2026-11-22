package app.streamsetu.tv.opening.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.opening.startup.AppRelease
import app.streamsetu.tv.opening.startup.StartupCoordinator
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.screens.library.PrimaryAction
import app.streamsetu.tv.ui.screens.library.StartBackground
import app.streamsetu.tv.ui.screens.library.TileIcon
import app.streamsetu.tv.ui.screens.library.riseIn
import app.streamsetu.tv.ui.theme.Tokens

/**
 * What's New for this release. Edit this list at each release, and keep only what is true on Android (the Mac's player-menu changes, for example, are not listed here).
 * The welcome's paste field does not exist on Android, so the second row speaks only of choosing how to connect.
 */
object WhatsNewContent {
    data class Row(val icon: ImageVector, val title: String, val text: String)
    val rows = listOf(
        Row(Icons.Filled.AutoAwesome, "A new look", "The silver television with its teal ribbon, on your home screen and inside the app."),
        Row(Icons.Filled.Bolt, "Start in seconds", "Choose how you connect, on a redesigned welcome."),
    )
}

/** Shown once after an update, when the opening has played: the release's changes, then Continue. It covers the app, which is already there underneath. */
@Composable
fun WhatsNewLayer(phone: Boolean) {
    if (!StartupCoordinator.showWhatsNew) return
    val done = { StartupCoordinator.whatsNewDone() }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { if (!phone) app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    BackHandler { done() }
    // The remote stays on this page while it is up, and touches do not reach the app underneath.
    Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { } }.focusProperties { exit = { FocusRequester.Cancel } }) {
        StartBackground(if (phone) Offset(0.5f, 0.1f) else Offset(0.15f, 0.25f))
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).then(if (phone) Modifier.windowInsetsPadding(WindowInsets.systemBars) else Modifier)
                .padding(horizontal = if (phone) 20.dp else Tokens.safeHorizontal + 40.dp, vertical = if (phone) 24.dp else Tokens.safeVertical + 12.dp)
                .widthIn(max = 760.dp).align(Alignment.Center),
            verticalArrangement = Arrangement.spacedBy(if (phone) 18.dp else 16.dp),
        ) {
            Label("WHAT'S NEW", 13.sp, Tokens.textSecondary, FontWeight.Bold, letterSpacing = 3.sp, modifier = Modifier.riseIn(0))
            Label("StreamSetu ${AppRelease.name}", if (phone) 32.sp else 44.sp, Tokens.text, FontWeight.Bold, maxLines = 2, letterSpacing = (-0.8).sp, modifier = Modifier.riseIn(1))
            WhatsNewContent.rows.forEachIndexed { i, r ->
                Row(Modifier.riseIn(2 + i), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    TileIcon(null, if (phone) 44.dp else 52.dp, fallback = r.icon)
                    Column(Modifier.weight(1f).padding(top = 2.dp)) {
                        Label(r.title, if (phone) 17.sp else 20.sp, Tokens.text, FontWeight.Bold, maxLines = 2)
                        Label(r.text, if (phone) 15.sp else 17.sp, Tokens.textSecondary, maxLines = 4, modifier = Modifier.padding(top = 2.dp))
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            PrimaryAction("Continue", done, (if (phone) Modifier.fillMaxWidth() else Modifier).focusRequester(first).riseIn(5))
        }
    }
}
