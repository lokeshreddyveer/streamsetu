package app.streamsetu.tv.ui.screens

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.AspectMode
import app.streamsetu.core.playback.EngineKind
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.playback.TrackOption
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

private enum class PanelKind(val title: String) { AUDIO("Audio"), SUBS("Subtitles"), SPEED("Speed"), PICTURE("Picture"), ENGINE("Player"), MORE("More"), CHANNELS("Channels") }

/**
 * The player, laid out like the iPhone app: title on top; at the bottom the progress bar and, for a live channel, the channel banner; under it a row of
 * chips (Audio, Subtitles, Speed, Picture, Player, More) that each open a small panel. Remote: OK pauses (live: opens the chips); ◀ ▶ skip 10 s
 * (live: ◀ channel list); ▲ ▼ change channel (live); ▼ in a movie goes to the chips; digits type a channel number; Back closes.
 */
@Composable
fun PlayerScreen(c: AppContainer, onClose: () -> Unit) {
    val playback = c.playback
    val state by playback.state.collectAsState()
    val current by playback.current.collectAsState()
    val speed by playback.speed.collectAsState()
    val aspect by playback.aspect.collectAsState()
    val resumedFrom by playback.resumedFrom.collectAsState()
    val engineNow by playback.engine.collectAsState()
    val audio by playback.audioTracks.collectAsState()
    val subs by playback.subtitleTracks.collectAsState()
    val favourites by c.user.favouriteIds().collectAsState(initial = emptySet())
    val item = current
    val live = item?.isLive == true

    var barVisible by remember { mutableStateOf(true) }
    var tick by remember { mutableIntStateOf(0) }
    var panel by remember { mutableStateOf<PanelKind?>(null) }
    var chipsFocused by remember { mutableStateOf(false) }
    var sleepAt by remember { mutableLongStateOf(0L) }
    var seekFlash by remember { mutableStateOf("") }
    var digits by remember { mutableStateOf("") }
    val root = remember { FocusRequester() }
    val chipsFirst = remember { FocusRequester() }
    val failFocus = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    fun poke() { barVisible = true; tick++ }
    fun toRoot() { runCatching { root.requestFocus() } }
    fun closePanel() { panel = null; toRoot() }

    BackHandler(enabled = panel != null) { closePanel() }
    BackHandler(enabled = panel == null && chipsFocused) { toRoot() }
    LaunchedEffect(sleepAt) { if (sleepAt > 0) { while (System.currentTimeMillis() < sleepAt) delay(1000); onClose() } }
    LaunchedEffect(Unit) { root.requestFocus() }
    LaunchedEffect(tick, state, chipsFocused, panel) { if (state == PlaybackState.Playing && !chipsFocused && panel == null) { delay(4500); barVisible = false } else barVisible = true }
    LaunchedEffect(seekFlash) { if (seekFlash.isNotEmpty()) { delay(900); seekFlash = "" } }
    LaunchedEffect(state is PlaybackState.Failed) { if (state is PlaybackState.Failed) { delay(200); runCatching { failFocus.requestFocus() } } }
    // Typing a channel number: after a short pause the channel with that number starts.
    LaunchedEffect(digits) {
        if (digits.isNotEmpty()) {
            delay(1600)
            val n = digits.toIntOrNull()
            c.queue.firstOrNull { it is ChannelPlayable && it.channel.number == n }?.let { c.play(it, c.queue) }
            digits = ""
        }
    }
    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    LaunchedEffect(Unit) { while (true) { position = playback.positionMs; duration = playback.durationMs; delay(500) } }
    var programmes by remember { mutableStateOf<List<EpgProgram>>(emptyList()) }
    LaunchedEffect(item?.id) { programmes = (item as? ChannelPlayable)?.channel?.epgId?.let { runCatching { c.epg.upcoming(c.db, it, 3) }.getOrNull() }.orEmpty() }
    val upNextVisible = item is EpisodePlayable && duration > 0 && duration - position in 1..30_000 && c.queue.indexOfFirst { it.id == item.id }.let { it >= 0 && it < c.queue.lastIndex }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(root).focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val code = e.nativeKeyEvent.keyCode
                if (code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_INFO || code == KeyEvent.KEYCODE_BUTTON_Y) { if (panel == null) panel = PanelKind.MORE else closePanel(); return@onPreviewKeyEvent true }
                if (panel != null || chipsFocused || state is PlaybackState.Failed) return@onPreviewKeyEvent false          // the focused list or button takes the keys
                if (live && (code in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 || code in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9)) {
                    digits = (digits + (if (code >= KeyEvent.KEYCODE_NUMPAD_0) code - KeyEvent.KEYCODE_NUMPAD_0 else code - KeyEvent.KEYCODE_0)).takeLast(4); poke(); return@onPreviewKeyEvent true
                }
                when (code) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                        when {
                            upNextVisible -> c.step(+1)
                            !barVisible -> poke()
                            live -> { runCatching { chipsFirst.requestFocus() } }
                            else -> { playback.togglePause(); poke() }
                        }; true
                    }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) { playback.seekBy(10_000); seekFlash = "+10 s"; poke() } else { poke(); runCatching { chipsFirst.requestFocus() } }; true }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) { playback.seekBy(-10_000); seekFlash = "−10 s"; poke() } else panel = PanelKind.CHANNELS; true }
                    KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP -> { if (live) c.step(+1); poke(); true }
                    KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN -> { if (live) c.step(-1) else if (barVisible) runCatching { chipsFirst.requestFocus() } else poke(); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> { c.step(+1); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { c.step(-1); poke(); true }
                    else -> false
                }
            },
    ) {
        EngineSurface(c, Modifier.fillMaxSize())
        val showInfo by c.settings.showStreamInfo.collectAsState()
        if (showInfo) {
            var info by remember { mutableStateOf("") }
            LaunchedEffect(state, engineNow) { while (true) { info = (playback.engineKind?.label ?: "") + " · " + playback.streamInfo(); delay(2000) } }
            Label(info, Tokens.caption, Color(0xCCFFFFFF), modifier = Modifier.align(Alignment.TopEnd).padding(24.dp))
        }

        // Status in the middle: loading, retrying, failed.
        Box(Modifier.align(Alignment.Center)) {
            when (val st = state) {
                PlaybackState.Resolving, PlaybackState.Buffering -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) { Spinner(); Label("Loading…", Tokens.small, Color(0xCCFFFFFF)) }
                is PlaybackState.Retrying -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) { Spinner(); Label(if (st.attempt == 0) "Trying another player…" else "Trying again (${st.attempt}) in ${st.inSeconds} s…", Tokens.small, Color(0xCCFFFFFF)) }
                is PlaybackState.Failed -> Column(Modifier.background(Color(0xE6101319), RoundedCornerShape(Tokens.radiusLarge)).padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Label("This stream did not play", Tokens.title, Tokens.text, FontWeight.Bold)
                    Label(st.error.message, Tokens.small, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 520.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        TvButton("Try Again", { playback.retryNow() }, Modifier.focusRequester(failFocus), primary = true)
                        if (live && c.queue.size > 1) TvButton("Next Channel", { c.step(+1) })
                        TvButton("Close", onClose)
                    }
                }
                PlaybackState.Ended -> Label("The end", Tokens.title, Tokens.text, FontWeight.Bold)
                else -> {}
            }
        }
        if (seekFlash.isNotEmpty()) Box(Modifier.align(Alignment.Center).background(Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 18.dp, vertical = 8.dp)) { Label(seekFlash, Tokens.heading, Tokens.text, FontWeight.Bold) }
        if (state == PlaybackState.Paused) Box(Modifier.align(Alignment.Center).size(72.dp).background(Color(0x99000000), CircleShape), Alignment.Center) { Image(Icons.Filled.PlayArrow, null, Modifier.size(40.dp), colorFilter = ColorFilter.tint(Color.White)) }
        if (digits.isNotEmpty()) Box(Modifier.align(Alignment.TopEnd).padding(36.dp).background(Color(0xCC000000), RoundedCornerShape(10.dp)).padding(horizontal = 16.dp, vertical = 8.dp)) { Label(digits, Tokens.display, Tokens.accent, FontWeight.Bold) }
        if (resumedFrom > 0 && position in 1..(resumedFrom + 9000)) Box(Modifier.align(Alignment.TopCenter).padding(top = 72.dp).background(Color(0xCC101319), RoundedCornerShape(50)).padding(horizontal = 16.dp, vertical = 7.dp)) { Label("Resumed at ${clock(resumedFrom)}  ·  ▼ then Start over to begin again", Tokens.small, Color.White) }
        if (upNextVisible && item is EpisodePlayable) {
            val next = c.queue.getOrNull(c.queue.indexOfFirst { it.id == item.id } + 1)
            if (next != null) Column(Modifier.align(Alignment.BottomEnd).padding(end = 48.dp, bottom = 190.dp).background(Color(0xE6101319), RoundedCornerShape(Tokens.radiusLarge)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Eyebrow("Up next", color = Tokens.accent)
                Label(next.title, Tokens.row, Color.White, FontWeight.SemiBold, modifier = Modifier.widthIn(max = 260.dp))
                Label("OK to play now", Tokens.caption, Color(0xB3FFFFFF))
            }
        }

        if (barVisible && item != null) {
            Box(Modifier.align(Alignment.TopStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xD9000000), Color.Transparent))).padding(horizontal = 48.dp, vertical = 26.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Label(if (item is EpisodePlayable) item.series.title else item.title, Tokens.title, Color.White, FontWeight.Bold)
                    if (item is EpisodePlayable) Label("Season ${item.episode.season} · Episode ${item.episode.number} · ${item.episode.title}", Tokens.small, Color(0xCCFFFFFF))
                }
            }
            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xEB000000)))).padding(start = 48.dp, end = 48.dp, top = 40.dp, bottom = 22.dp)) {
                if (item is ChannelPlayable) LiveBanner(item.channel, programmes) else VodControls(position, duration, state == PlaybackState.Playing || state == PlaybackState.Buffering)
                Spacer(Modifier.height(10.dp))
                // The chips, like the iPhone app: each opens a small panel.
                Row(Modifier.fillMaxWidth().onFocusChanged { chipsFocused = it.hasFocus }.onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionUp) { toRoot(); true } else false }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val audioName = audio.firstOrNull { it.selected }?.label
                    val subName = subs.firstOrNull { it.selected }?.label ?: "Off"
                    PlayerChip(Icons.Filled.Audiotrack, "Audio" + (audioName?.let { ": $it" } ?: ""), Modifier.focusRequester(chipsFirst)) { panel = PanelKind.AUDIO }
                    PlayerChip(Icons.Filled.Subtitles, "Subtitles: $subName") { panel = PanelKind.SUBS }
                    if (!live) PlayerChip(Icons.Filled.Speed, if (speed == 1f) "Speed" else "${speed}×") { panel = PanelKind.SPEED }
                    PlayerChip(Icons.Filled.AspectRatio, aspect.label) { panel = PanelKind.PICTURE }
                    PlayerChip(Icons.Filled.Tune, playback.engineKind?.label ?: "Player") { panel = PanelKind.ENGINE }
                    if (!live && resumedFrom > 0) PlayerChip(Icons.Filled.Replay, "Start over") { playback.startOver() }
                    if (live && c.queue.size > 1) PlayerChip(Icons.Filled.FormatListBulleted, "Channels") { panel = PanelKind.CHANNELS }
                    PlayerChip(Icons.Filled.MoreHoriz, "More") { panel = PanelKind.MORE }
                }
                Label(if (live) "▲ ▼ channel      ◀ channels      OK options      0–9 channel number      BACK close" else "◀ ▶ skip 10 s      OK pause      ▼ options      BACK close", Tokens.caption, Color(0x80FFFFFF), modifier = Modifier.padding(top = 8.dp))
            }
        }

        panel?.let { kind ->
            val selectedReq = remember(kind) { FocusRequester() }
            LaunchedEffect(kind) { delay(120); runCatching { selectedReq.requestFocus() } }
            Column(Modifier.align(Alignment.CenterEnd).padding(end = 24.dp).width(330.dp).fillMaxHeight(0.88f).background(Color(0xF2101319), RoundedCornerShape(Tokens.radiusLarge)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label(kind.title, Tokens.heading, Tokens.text, FontWeight.Bold)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    when (kind) {
                        PanelKind.AUDIO -> {
                            if (audio.isEmpty()) item { Label("Only one audio track.", Tokens.small, Tokens.textTertiary) }
                            items(audio, key = { "a" + it.id }) { t -> OptionRow(t.label, t.selected, if (t.selected) selectedReq else null) { playback.selectAudio(t.id); closePanel() } }
                        }
                        PanelKind.SUBS -> {
                            item { OptionRow("Off", subs.none { it.selected }, if (subs.none { it.selected }) selectedReq else null) { playback.selectSubtitle(null); closePanel() } }
                            items(subs, key = { "s" + it.id }) { t -> OptionRow(t.label, t.selected, if (t.selected) selectedReq else null) { playback.selectSubtitle(t.id); closePanel() } }
                        }
                        PanelKind.SPEED -> items(listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f), key = { "v$it" }) { v -> OptionRow(if (v == 1f) "Normal" else "${v}×", v == speed, if (v == speed) selectedReq else null) { playback.setSpeed(v); closePanel() } }
                        PanelKind.PICTURE -> items(AspectMode.entries, key = { "p" + it.name }) { m -> OptionRow(m.label, m == aspect, if (m == aspect) selectedReq else null) { playback.setAspect(m); closePanel() } }
                        PanelKind.ENGINE -> {
                            items(playback.available.toList(), key = { "e" + it.name }) { k -> OptionRow(k.label + if (k == EngineKind.MPV) "  ·  MKV, AVI, unusual formats" else "  ·  HLS, MP4, transport streams", k == playback.engineKind, if (k == playback.engineKind) selectedReq else null) { playback.switchEngine(k); closePanel() } }
                        }
                        PanelKind.CHANNELS -> {
                            val list = c.queue.filterIsInstance<ChannelPlayable>()
                            items(list, key = { "c" + it.id }) { ch -> OptionRow("${ch.channel.number ?: ""}  ${ch.channel.name}".trim(), ch.id == item?.id, if (ch.id == item?.id) selectedReq else null) { c.play(ch, c.queue); closePanel() } }
                        }
                        PanelKind.MORE -> {
                            item { OptionRow("Sleep timer: " + if (sleepAt > 0) "on" else "off", false, selectedReq) { sleepAt = if (sleepAt == 0L) System.currentTimeMillis() + 30 * 60_000L else 0L; closePanel() } }
                            if (live && item != null) item { OptionRow(if (item.id in favourites) "Remove from favorites" else "Add to favorites", item.id in favourites, null) { scope.launch { c.user.setFavourite(item.id, ContentKind.CHANNEL, item.id !in favourites) }; closePanel() } }
                            if (live && c.previousLive != null) item { OptionRow("Last channel", false, null) { c.lastChannel(); closePanel() } }
                            item { val on by c.settings.showStreamInfo.collectAsState(); OptionRow("Stream information: " + if (on) "on" else "off", on, null) { c.settings.setShowStreamInfo(!on); closePanel() } }
                            if (android.os.Build.VERSION.SDK_INT >= 26) item { OptionRow("Picture in Picture", false, null) { closePanel(); (context as? android.app.Activity)?.enterPictureInPictureMode(android.app.PictureInPictureParams.Builder().build()) } }
                            item { OptionRow("Close player", false, null) { onClose() } }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PlayerChip(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = Color(0x40FFFFFF), focusedContainer = Color(0xFFFFFFFF), scaleOnFocus = 1.05f) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(if (f) Color.Black else Color.White))
            Label(label, Tokens.small, if (f) Color.Black else Color.White, FontWeight.Medium, modifier = Modifier.widthIn(max = 200.dp))
        }
    }
}

@Composable
private fun OptionRow(label: String, selected: Boolean, requester: FocusRequester?, onClick: () -> Unit) {
    Focusable(onClick, (if (requester != null) Modifier.focusRequester(requester) else Modifier).fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Label(label, Tokens.row, if (selected) Tokens.accent else Tokens.text, modifier = Modifier.weight(1f))
            if (selected) Image(Icons.Filled.Check, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(Tokens.accent))
        }
    }
}

/** A movie or episode: the bar with a thumb, the times, and round controls like a streaming app. */
@Composable
private fun VodControls(position: Long, duration: Long, playing: Boolean) {
    val frac = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
    BoxWithConstraints(Modifier.fillMaxWidth().height(16.dp), contentAlignment = Alignment.CenterStart) {
        Box(Modifier.fillMaxWidth().height(4.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp)))
        Box(Modifier.fillMaxWidth(frac).height(4.dp).background(Tokens.playPill, RoundedCornerShape(2.dp)))
        Box(Modifier.offset(x = (maxWidth * frac) - 7.dp).size(14.dp).background(Color.White, CircleShape))
    }
    Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Label(clock(position), Tokens.small, Color.White, FontWeight.Medium)
        Label("−" + clock((duration - position).coerceAtLeast(0)), Tokens.small, Color(0xCCFFFFFF))
    }
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        RoundIcon(Icons.Filled.Replay10, 40)
        Spacer(Modifier.width(18.dp))
        RoundIcon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, 54, filled = true)
        Spacer(Modifier.width(18.dp))
        RoundIcon(Icons.Filled.Forward10, 40)
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, size: Int, filled: Boolean = false) {
    Box(Modifier.size(size.dp).clip(CircleShape).background(if (filled) Color.White else Color(0x33FFFFFF)), Alignment.Center) {
        Image(icon, null, Modifier.size((size * 0.55f).dp), colorFilter = ColorFilter.tint(if (filled) Color.Black else Color.White))
    }
}

/** A live channel: logo, number, name, a LIVE badge, what is on now with a progress bar, and what is next. */
@Composable
private fun LiveBanner(ch: Channel, programmes: List<EpgProgram>) {
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    val now = System.currentTimeMillis()
    val current = programmes.firstOrNull { it.isLive(now) }
    val next = programmes.firstOrNull { it.startMs > now }
    Row(Modifier.fillMaxWidth().background(Color(0x99101319), RoundedCornerShape(Tokens.radiusLarge)).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
        ChannelLogo(ch.logoUrl, ch.name, 52.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ch.number?.let { Label("$it", Tokens.heading, Tokens.accent, FontWeight.Bold) }
                Label(ch.name, Tokens.heading, Color.White, FontWeight.Bold, modifier = Modifier.weight(1f, fill = false))
                Box(Modifier.background(Color(0xFFE5484D), RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label("LIVE", Tokens.caption, Color.White, FontWeight.Bold) }
            }
            if (current != null) {
                Label("${current.title}   ${time.format(Date(current.startMs))} – ${time.format(Date(current.endMs))}", Tokens.small, Color(0xE6FFFFFF))
                val frac = ((now - current.startMs).toFloat() / (current.endMs - current.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
                Box(Modifier.fillMaxWidth().height(3.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
            } else Label("Live", Tokens.small, Color(0xCCFFFFFF))
            if (next != null) Label("Next · ${time.format(Date(next.startMs))}  ${next.title}", Tokens.caption, Color(0xA6FFFFFF))
        }
    }
}

private fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
