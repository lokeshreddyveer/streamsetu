package app.streamsetu.tv.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.playback.BufferingMode
import app.streamsetu.core.playback.EngineEvent
import app.streamsetu.core.playback.EngineRequest
import app.streamsetu.core.playback.ExoEngine
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.phone.Sheet
import app.streamsetu.tv.ui.phone.SheetItem
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/** One picture in Multi-View: the channel and the player that shows it. */
private class Tile(val channel: Channel, val engine: ExoEngine) {
    var status by mutableStateOf("Loading…")
}

/**
 * Several live channels on one screen, up to four. One has sound; tap (or press OK on) another to move the sound. The first channel is the one that was playing. A provider that allows
 * only one stream at a time will play only one of them, which the screen says. Leaving closes every stream.
 */
@Composable
fun MultiViewScreen(c: AppContainer, onClose: () -> Unit, onFullScreen: (Channel) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tiles = remember { mutableStateListOf<Tile>() }
    var audio by remember { mutableIntStateOf(0) }
    var picking by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Int?>(null) }

    fun addTile(ch: Channel) {
        if (tiles.size >= 4 || tiles.any { it.channel.id == ch.id }) return
        val engine = ExoEngine(context)
        val tile = Tile(ch, engine)
        engine.onEvent = { ev -> tile.status = when (ev) { is EngineEvent.Ready -> ""; EngineEvent.Buffering -> "Loading…"; is EngineEvent.Error -> "Did not play"; else -> tile.status } }
        tiles += tile
        scope.launch {
            val url = c.resolver.resolve(ch.sourceId, ch.streamRef)
            if (url == null) { tile.status = "No address"; return@launch }
            val ua = c.resolver.userAgent(ch.sourceId)
            engine.load(EngineRequest(url, (if (ua != null) mapOf("User-Agent" to ua) else emptyMap()) + c.resolver.headers(ch.sourceId), 0, true, BufferingMode.AUTOMATIC))
        }
    }
    LaunchedEffect(Unit) { if (tiles.isEmpty()) c.multiViewStart.forEach { addTile(it) } }
    LaunchedEffect(audio, tiles.size) { tiles.forEachIndexed { i, t -> t.engine.setVolume(if (i == audio) 1f else 0f) } }
    DisposableEffect(Unit) { onDispose { tiles.forEach { runCatching { it.engine.stop(); it.engine.release() } }; tiles.clear() } }
    BackHandler(enabled = true) { if (picking) picking = false else if (menuFor != null) menuFor = null else onClose() }

    val oneConnection = tiles.map { it.channel.sourceId }.distinct().any { id -> c.resolver.allowsOnlyOneStream(id) && tiles.count { it.channel.sourceId == id } > 1 }
    Column(Modifier.fillMaxSize().background(Color.Black).windowInsetsPadding(WindowInsets.systemBars)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Label("Multi-View", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.weight(1f))
            if (tiles.size < 4) TvButton("Add a channel", { picking = true }, icon = Icons.Filled.Add)
            TvButton("Close", onClose, icon = Icons.Filled.Close)
        }
        if (oneConnection) Label("This provider allows one stream at a time, so only one of these will play.", Tokens.small, Tokens.warning, modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp), maxLines = 2)
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(6.dp)) {
            val wide = maxWidth > maxHeight
            val cells = tiles.toList()
            if (cells.isEmpty()) Box(Modifier.fillMaxSize(), Alignment.Center) { Label("Add a channel to begin", Tokens.body, Tokens.textSecondary) }
            else {
                val columns = if (cells.size == 1) 1 else if (cells.size == 2) (if (wide) 2 else 1) else 2
                val rows = (cells.size + columns - 1) / columns
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    for (r in 0 until rows) Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        for (col in 0 until columns) {
                            val i = r * columns + col
                            val t = cells.getOrNull(i)
                            if (t == null) Spacer(Modifier.weight(1f)) else key(t.channel.id) {
                                Focusable({ if (audio == i) menuFor = i else audio = i }, Modifier.weight(1f).fillMaxHeight(), shape = RoundedCornerShape(8.dp), container = Color.Black, scaleOnFocus = 1.0f, onLongClick = { menuFor = i }) { _ ->
                                    AndroidView(factory = { ctx -> android.widget.FrameLayout(ctx).also { f -> val v = t.engine.view(ctx); (v.parent as? android.view.ViewGroup)?.removeView(v); f.addView(v) } }, modifier = Modifier.fillMaxSize())
                                    Row(Modifier.align(Alignment.TopStart).padding(6.dp).background(Color(0x99000000), RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                        androidx.compose.foundation.Image(if (audio == i) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, null, Modifier.size(14.dp), colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(if (audio == i) Tokens.accent else Tokens.textTertiary))
                                        Label(t.channel.name, Tokens.small, Tokens.text, FontWeight.Medium, maxLines = 1)
                                    }
                                    if (t.status.isNotEmpty()) Label(t.status, Tokens.small, Tokens.textSecondary, modifier = Modifier.align(Alignment.Center))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (picking) {
        // The list the player was started from; when that is just one channel, the channels of the same connection.
        var pool by remember { mutableStateOf(c.queue.filterIsInstance<ChannelPlayable>().map { it.channel }) }
        LaunchedEffect(Unit) {
            if (pool.size <= 1) {
                val source = tiles.firstOrNull()?.channel?.sourceId ?: c.sources.all().firstOrNull { !it.draft && it.channelCount > 0 }?.id
                if (source != null) { val hidden = c.db.extras().hiddenChannelIds().toSet(); pool = c.db.catalog().managerChannels(source, "", 300).filter { it.id !in hidden }.map { it.toModel() } }
            }
        }
        val choices = pool.filter { ch -> tiles.none { it.channel.id == ch.id } }.take(200)
        Sheet("Add a channel", if (choices.isEmpty()) listOf(SheetItem("No other channels in this list", null, false) {}) else choices.map { ch -> SheetItem(ch.name, null, false) { addTile(ch) } }, onClose = { picking = false }, subtitle = "From the list you were watching")
    }
    menuFor?.let { i ->
        val t = tiles.getOrNull(i)
        if (t != null) Sheet(t.channel.name, listOf(
            SheetItem("Sound from this one", Icons.Filled.VolumeUp) { audio = i },
            SheetItem("Watch full screen", Icons.Filled.Fullscreen) { onFullScreen(t.channel) },
            SheetItem("Remove", Icons.Filled.Close) { runCatching { t.engine.stop(); t.engine.release() }; tiles.removeAt(i); audio = audio.coerceAtMost((tiles.size - 1).coerceAtLeast(0)) },
        ), onClose = { menuFor = null })
    }
}
