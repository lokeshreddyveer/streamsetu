package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.phone.Sheet
import app.streamsetu.tv.ui.phone.SheetItem
import app.streamsetu.tv.ui.theme.Tokens
import app.streamsetu.tv.update.UpdateState

/**
 * Tells the person a newer version exists, once, when the automatic check found it. It stays out of the way of the player ([suppress]).
 * Choosing to update downloads and checks the file, then the system installer asks for the final confirmation.
 */
@Composable
fun TvUpdatePrompt(c: AppContainer, suppress: Boolean) {
    val show by c.updates.prompt.collectAsState()
    val st by c.updates.state.collectAsState()
    val offer = st as? UpdateState.Available
    if (show && offer != null && !suppress) ContextMenu(
        "Update available", "StreamSetu ${offer.release.version} is ready. The installer will ask you to confirm.",
        listOf(
            MenuAction("Download and install", Icons.Filled.SystemUpdate) { c.updates.downloadAndInstall() },
            MenuAction("Later", Icons.Filled.Schedule) { c.updates.dismissPrompt() },
            MenuAction("Skip this version", Icons.Filled.Block) { c.updates.dismissPrompt(skipVersion = true) },
        ),
        onClose = { c.updates.dismissPrompt() },
    )
    DownloadCard(st)
}

@Composable
fun PhoneUpdatePrompt(c: AppContainer, suppress: Boolean) {
    val show by c.updates.prompt.collectAsState()
    val st by c.updates.state.collectAsState()
    val offer = st as? UpdateState.Available
    if (show && offer != null && !suppress) Sheet(
        "Update available",
        listOf(
            SheetItem("Download and install", Icons.Filled.SystemUpdate) { c.updates.downloadAndInstall() },
            SheetItem("Later", Icons.Filled.Schedule) { c.updates.dismissPrompt() },
            SheetItem("Skip this version", Icons.Filled.Block) { c.updates.dismissPrompt(skipVersion = true) },
        ),
        onClose = { c.updates.dismissPrompt() },
        subtitle = "StreamSetu ${offer.release.version} is ready. The installer will ask you to confirm.",
    )
    DownloadCard(st)
}

/** A small note at the bottom while the update downloads, and a plain line if it could not be used. */
@Composable
private fun DownloadCard(st: UpdateState) {
    val text = when (st) {
        is UpdateState.Downloading -> "Downloading the update…  ${st.percent}%"
        is UpdateState.NeedsPermission -> "Allow StreamSetu to install apps in the screen that opened, then open Settings, About and press Install."
        else -> null
    } ?: return
    Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 90.dp), Alignment.BottomCenter) {
        Label(text, 13.sp, Tokens.text, FontWeight.Medium, maxLines = 3, modifier = Modifier.background(Color(0xE6101216), RoundedCornerShape(14.dp)).padding(horizontal = 16.dp, vertical = 10.dp).widthIn(max = 420.dp))
    }
}
