package app.streamsetu.tv.ui.screens.settings

import android.os.Build
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.MoviePlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.DeviceItem
import app.streamsetu.tv.DeviceMedia
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Settings, On Your Device: the videos and pictures stored on this device. A video plays here; a picture opens in a viewer. Nothing is copied or sent. */
@Composable
fun DeviceSettings(c: AppContainer, nav: Navigator) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(DeviceMedia.granted(context)) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted = DeviceMedia.granted(context) }
    var pictures by remember { mutableStateOf(false) }
    var shown by remember { mutableIntStateOf(40) }
    var viewing by remember { mutableStateOf<Int?>(null) }
    var items by remember { mutableStateOf<List<DeviceItem>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(granted, pictures) {
        if (!granted) return@LaunchedEffect
        loaded = false; shown = 40
        items = withContext(Dispatchers.IO) { if (pictures) DeviceMedia.pictures(context) else DeviceMedia.videos(context) }
        loaded = true
    }
    SettingGroup("On Your Device", "The videos and pictures stored on this device. They are shown and played from where they are; nothing is copied or sent anywhere.") {
        if (!granted) ActionRow("Allow access to videos and pictures", "Android asks once. You can change this later in the device's settings.", "Allow", confirm = false) { ask.launch(DeviceMedia.permissions()) }
        else {
            ChoiceRow("Show", options = listOf(false to "Videos", true to "Pictures"), value = pictures) { pictures = it }
            if (!loaded) InfoRow("Reading…", "")
            else if (items.isEmpty()) InfoRow(if (pictures) "No pictures on this device" else "No videos on this device", "")
        }
    }
    if (granted && items.isNotEmpty()) SettingGroup(if (pictures) "Pictures" else "Videos") {
        items.take(shown).forEachIndexed { i, it ->
            val detail = if (it.video) DeviceMedia.clock(it.durationMs) + "  ·  " + app.streamsetu.core.data.repo.SavedTitles.size(it.sizeBytes) else app.streamsetu.core.data.repo.SavedTitles.size(it.sizeBytes)
            ActionRow(it.name.ifBlank { "Untitled" }, detail, if (it.video) "Play" else "View", confirm = false) {
                if (it.video) app.streamsetu.tv.play(c, nav, MoviePlayable(Movie(DeviceMedia.playId(it.uri), "device", null, it.name.substringBeforeLast('.').ifBlank { "Video" }, null, null, null, null, "", 0)))
                else viewing = i
            }
        }
        if (items.size > shown) ActionRow("Show more", "${items.size - shown} more", "Show", confirm = false) { shown += 40 }
    }
    viewing?.let { start -> PictureViewer(items.filter { !it.video }, start.coerceAtMost((items.size - 1).coerceAtLeast(0)), onClose = { viewing = null }) }
}

/** A picture full screen, stepped with Left and Right (or the buttons), closed with Back. */
@Composable
private fun PictureViewer(pictures: List<DeviceItem>, start: Int, onClose: () -> Unit) {
    if (pictures.isEmpty()) return
    var index by remember { mutableIntStateOf(start.coerceIn(0, pictures.lastIndex)) }
    val context = LocalContext.current
    val item = pictures[index]
    val bitmap by produceState<android.graphics.Bitmap?>(null, item.uri) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val uri = android.net.Uri.parse(item.uri)
                if (Build.VERSION.SDK_INT >= 29) context.contentResolver.loadThumbnail(uri, Size(1600, 1600), null)
                else context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it) }
            }.getOrNull()
        }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), Alignment.Center) {
            bitmap?.let { Image(it.asImageBitmap(), item.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) } ?: Label("Loading…", Tokens.row, Tokens.textSecondary)
            Row(Modifier.align(Alignment.BottomCenter).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                TvButton("Previous", { if (index > 0) index-- })
                Label("${index + 1} of ${pictures.size}", Tokens.row, Tokens.text, FontWeight.SemiBold)
                TvButton("Next", { if (index < pictures.lastIndex) index++ })
                TvButton("Close", onClose)
            }
        }
    }
}
