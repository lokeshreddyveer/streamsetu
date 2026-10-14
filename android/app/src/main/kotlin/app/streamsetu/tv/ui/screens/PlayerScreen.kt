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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.playback.TrackOption
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

/**
 * The player, like a streaming app. A movie or episode: title on top; at the bottom a progress bar with the time played and left, and the controls.
 * A live channel: a channel banner with the logo, number, what is on now with its progress, and what is next.
 * Remote: OK pauses; ◀ ▶ skip 10 s; ▲ ▼ change channel (live); ▼ in a movie, or MENU, opens audio and subtitles; Back closes.
 */
@Composable
fun PlayerScreen(c: AppContainer, onClose: () -> Unit) {
    val playback = c.playback
    val state by playback.state.collectAsState()
    val current by playback.current.collectAsState()
    var barVisible by remember { mutableStateOf(true) }
    var tick by remember { mutableIntStateOf(0) }
    val focus = remember { FocusRequester() }
    val item = current
    val audio by playback.audioTracks.collectAsState()
    val subs by playback.subtitleTracks.collectAsState()
    var panel by remember { mutableStateOf(false) }
    var sleepAt by remember { mutableLongStateOf(0L) }
    var seekFlash by remember { mutableStateOf("") }
    BackHandler(enabled = panel) { panel = false }
    LaunchedEffect(sleepAt) { if (sleepAt > 0) { while (System.currentTimeMillis() < sleepAt) delay(1000); onClose() } }

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(tick, state) { if (state == PlaybackState.Playing) { delay(4500); barVisible = false } else barVisible = true }
    LaunchedEffect(seekFlash) { if (seekFlash.isNotEmpty()) { delay(900); seekFlash = "" } }
    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    LaunchedEffect(Unit) { while (true) { position = playback.positionMs; duration = playback.durationMs; delay(500) } }
    // What is on this channel now and next.
    var programmes by remember { mutableStateOf<List<EpgProgram>>(emptyList()) }
    LaunchedEffect(item?.id) { programmes = (item as? ChannelPlayable)?.channel?.epgId?.let { runCatching { c.epg.upcoming(c.db, it, 3) }.getOrNull() }.orEmpty() }

    fun poke() { barVisible = true; tick++ }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(focus).focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val live = item?.isLive == true
                val code = e.nativeKeyEvent.keyCode
                if (code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_INFO || code == KeyEvent.KEYCODE_BUTTON_Y) { panel = !panel; return@onPreviewKeyEvent true }
                if (panel) return@onPreviewKeyEvent false          // the list takes the arrow keys
                when (code) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> { if (barVisible && !live) playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) { playback.seekBy(10_000); seekFlash = "+10 s" }; poke(); true }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) { playback.seekBy(-10_000); seekFlash = "−10 s" }; poke(); true }
                    KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP -> { if (live) c.step(+1) else { barVisible = true; tick++ }; poke(); true }
                    KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN -> { if (live) c.step(-1) else panel = true; poke(); true }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> { c.step(+1); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { c.step(-1); poke(); true }
                    else -> false
                }
            },
    ) {
        // The picture comes from whichever engine is playing (ExoPlayer or MPV); switching engine swaps the view.
        val engine by playback.engine.collectAsState()
        AndroidView(
            factory = { ctx -> android.widget.FrameLayout(ctx) },
            update = { frame ->
                val e = engine
                val view = e?.view(frame.context)
                if (view != null && frame.tag !== e) {
                    frame.removeAllViews(); (view.parent as? android.view.ViewGroup)?.removeView(view)
                    frame.addView(view, android.widget.FrameLayout.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT))
                    frame.tag = e
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
        val showInfo by c.settings.showStreamInfo.collectAsState()
        if (showInfo) {
            var info by remember { mutableStateOf("") }
            LaunchedEffect(state, engine) { while (true) { info = (playback.engineKind?.label ?: "") + " · " + playback.streamInfo(); delay(2000) } }
            Label(info, Tokens.caption, Color(0xCCFFFFFF), modifier = Modifier.align(Alignment.TopEnd).padding(24.dp))
        }

        // Status in the middle: loading, retrying, failed.
        Box(Modifier.align(Alignment.Center)) {
            when (val s = state) {
                PlaybackState.Resolving, PlaybackState.Buffering -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) { Spinner(); Label("Loading…", Tokens.small, Color(0xCCFFFFFF)) }
                is PlaybackState.Retrying -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) { Spinner(); Label(if (s.attempt == 0) "Trying another player…" else "Trying again (${s.attempt}) in ${s.inSeconds} s…", Tokens.small, Color(0xCCFFFFFF)) }
                is PlaybackState.Failed -> Column(Modifier.background(Color(0xE6101319), RoundedCornerShape(Tokens.radiusLarge)).padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Label("This stream did not play", Tokens.title, Tokens.text, FontWeight.Bold)
                    Label(s.error.message, Tokens.small, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 520.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { TvButton("Try Again", { playback.retryNow() }, primary = true); TvButton("Close", onClose) }
                }
                PlaybackState.Ended -> Label("The end", Tokens.title, Tokens.text, FontWeight.Bold)
                else -> {}
            }
        }
        if (seekFlash.isNotEmpty()) Box(Modifier.align(Alignment.Center).background(Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 18.dp, vertical = 8.dp)) { Label(seekFlash, Tokens.heading, Tokens.text, FontWeight.Bold) }

        if (state == PlaybackState.Paused) Box(Modifier.align(Alignment.Center).size(72.dp).background(Color(0x99000000), CircleShape), Alignment.Center) { Image(Icons.Filled.PlayArrow, null, Modifier.size(40.dp), colorFilter = ColorFilter.tint(Color.White)) }

        if (barVisible && item != null) {
            // Top: title
            Box(Modifier.align(Alignment.TopStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xD9000000), Color.Transparent))).padding(horizontal = 48.dp, vertical = 26.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Label(if (item is EpisodePlayable) item.series.title else item.title, Tokens.title, Color.White, FontWeight.Bold)
                    if (item is EpisodePlayable) Label("Season ${item.episode.season} · Episode ${item.episode.number} · ${item.episode.title}", Tokens.small, Color(0xCCFFFFFF))
                }
            }
            // Bottom: live banner or the movie controls
            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xEB000000)))).padding(start = 48.dp, end = 48.dp, top = 40.dp, bottom = 26.dp)) {
                if (item is ChannelPlayable) LiveBanner(item.channel, programmes) else VodControls(position, duration, state == PlaybackState.Playing || state == PlaybackState.Buffering, item is EpisodePlayable)
                Label(if (item.isLive) "▲ ▼ channel      MENU audio & subtitles      BACK stop" else "◀ ▶ skip 10 s      OK pause      ▼ audio & subtitles      BACK stop", Tokens.caption, Color(0x99FFFFFF), modifier = Modifier.padding(top = 10.dp))
            }
        }

        if (panel) {
            Column(Modifier.align(Alignment.CenterEnd).padding(end = 24.dp).width(320.dp).fillMaxHeight(0.86f).background(Color(0xF2101319), RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label("Audio & Subtitles", Tokens.heading, Tokens.text, FontWeight.Bold)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    item { Eyebrow("Audio", Modifier.padding(top = 4.dp)) }
                    if (audio.isEmpty()) item { Label("Only one audio track.", Tokens.small, Tokens.textTertiary) }
                    items(audio, key = { "a" + it.id }) { t -> TrackRow(t) { playback.selectAudio(t.id) } }
                    item { Eyebrow("Subtitles", Modifier.padding(top = 10.dp)) }
                    item { Focusable({ playback.selectSubtitle(null) }, Modifier.fillMaxWidth()) { Label("Off", Tokens.row, if (subs.none { it.selected }) Tokens.accent else Tokens.text, modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp)) } }
                    items(subs, key = { "s" + it.id }) { t -> TrackRow(t) { playback.selectSubtitle(t.id) } }
                    item { Eyebrow("Sleep timer", Modifier.padding(top = 10.dp)) }
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            listOf(30, 60, 90).forEach { m -> TvButton("$m min", { sleepAt = System.currentTimeMillis() + m * 60_000L; panel = false }) }
                            if (sleepAt > 0) TvButton("Off", { sleepAt = 0 })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackRow(t: TrackOption, onClick: () -> Unit) {
    Focusable(onClick, Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Label(t.label, Tokens.row, if (t.selected) Tokens.accent else Tokens.text, modifier = Modifier.weight(1f))
            if (t.selected) Image(Icons.Filled.Check, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(Tokens.accent))
        }
    }
}

/** A movie or episode: the bar with a thumb, the times, and round controls like a streaming app. */
@Composable
private fun VodControls(position: Long, duration: Long, playing: Boolean, episode: Boolean) {
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
        Spacer(Modifier.width(34.dp))
        RoundIcon(Icons.Filled.Subtitles, 40)
        if (episode) { Spacer(Modifier.width(18.dp)); RoundIcon(Icons.Filled.SkipNext, 40) }
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
