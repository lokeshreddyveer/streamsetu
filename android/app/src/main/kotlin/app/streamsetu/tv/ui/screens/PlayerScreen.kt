package app.streamsetu.tv.ui.screens

import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.core.playback.TrackOption
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Spinner
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/**
 * Full-screen player. The remote: OK shows or hides the bar (and pauses when the bar is already showing);
 * left and right skip 10 s in a movie; up and down change channel; play/pause and the media keys work as expected; Back closes.
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
    BackHandler(enabled = panel) { panel = false }
    LaunchedEffect(sleepAt) { if (sleepAt > 0) { while (System.currentTimeMillis() < sleepAt) delay(1000); onClose() } }

    LaunchedEffect(Unit) { focus.requestFocus() }
    // The bar hides by itself a few seconds after the last key, while playing.
    LaunchedEffect(tick, state) { if (state == PlaybackState.Playing) { delay(4000); barVisible = false } else barVisible = true }
    // A clock for the progress bar.
    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    LaunchedEffect(Unit) { while (true) { position = playback.positionMs; duration = playback.durationMs; delay(500) } }

    fun poke() { barVisible = true; tick++ }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(focus).focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                if (e.nativeKeyEvent.keyCode == KeyEvent.KEYCODE_MENU || e.nativeKeyEvent.keyCode == KeyEvent.KEYCODE_INFO || e.nativeKeyEvent.keyCode == KeyEvent.KEYCODE_BUTTON_Y) { panel = !panel; return@onPreviewKeyEvent true }
                if (panel) return@onPreviewKeyEvent false          // the list takes the arrow keys
                val live = item?.isLive == true
                when (e.nativeKeyEvent.keyCode) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER ->
                        { if (barVisible && !live) playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) playback.seekBy(10_000); poke(); true }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) playback.seekBy(-10_000); poke(); true }
                    KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_MEDIA_NEXT -> { c.step(+1); poke(); true }
                    KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { c.step(-1); poke(); true }
                    else -> false
                }
            },
    ) {
        AndroidView(
            factory = { ctx -> PlayerView(ctx).apply { player = playback.player; useController = false; resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT; keepScreenOn = true } },
            modifier = Modifier.fillMaxSize(),
        )

        // Status in the middle: loading, retrying, failed.
        Box(Modifier.align(Alignment.Center)) {
            when (val s = state) {
                PlaybackState.Resolving, PlaybackState.Buffering -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) { Spinner(); Label("Loading…") }
                is PlaybackState.Retrying -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Spinner(); Spacer(Modifier.height(8.dp)); Label("Trying again (${s.attempt}) in ${s.inSeconds} s…", color = Tokens.muted)
                }
                is PlaybackState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Label("This stream did not play", Tokens.title, Tokens.text, FontWeight.Bold)
                    Label(s.error.message, color = Tokens.muted, maxLines = 3, modifier = Modifier.widthIn(max = 700.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { TvButton("Try Again", { playback.retryNow() }, primary = true); TvButton("Close", onClose) }
                }
                PlaybackState.Ended -> Label("The end", Tokens.title)
                else -> {}
            }
        }

        if (barVisible && item != null) {
            Box(Modifier.align(Alignment.TopStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xCC000000), Color.Transparent))).padding(horizontal = 56.dp, vertical = 32.dp)) {
                Label(item.title, Tokens.title, Tokens.text, FontWeight.Bold)
            }
            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xDD000000)))).padding(horizontal = 56.dp, vertical = 32.dp)) {
                if (item.isLive) {
                    Label("LIVE · ▲▼ change channel · MENU audio & subtitles", Tokens.small, Tokens.accent, FontWeight.SemiBold)
                } else {
                    ProgressBar(if (duration > 0) position.toFloat() / duration else 0f)
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        Label(clock(position), Tokens.small, Tokens.muted); Label("◀▶ skip 10 s · OK pause · MENU audio & subtitles", Tokens.small, Tokens.muted); Label(clock(duration), Tokens.small, Tokens.muted)
                    }
                }
                if (state == PlaybackState.Paused) Label("Paused", Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
            }
        }

        if (panel) {
            Column(Modifier.align(Alignment.CenterEnd).width(420.dp).fillMaxHeight().background(Color(0xEE0B0D12)).padding(28.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label("Audio and subtitles", Tokens.heading, Tokens.text, FontWeight.Bold)
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { Label("Audio", Tokens.small, Tokens.muted) }
                    items(audio, key = { "a" + it.id }) { t -> TrackRow(t) { playback.selectAudio(t.id) } }
                    item { Label("Subtitles", Tokens.small, Tokens.muted, modifier = Modifier.padding(top = 10.dp)) }
                    item { Focusable({ playback.selectSubtitle(null) }, Modifier.fillMaxWidth()) { Label("Off", modifier = Modifier.padding(12.dp), color = if (subs.none { it.selected }) Tokens.accent else Tokens.text) } }
                    items(subs, key = { "s" + it.id }) { t -> TrackRow(t) { playback.selectSubtitle(t.id) } }
                    item { Label("Sleep timer", Tokens.small, Tokens.muted, modifier = Modifier.padding(top = 10.dp)) }
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(30, 60, 90).forEach { m -> TvButton("${m} min", { sleepAt = System.currentTimeMillis() + m * 60_000L; panel = false }) }
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
    Focusable(onClick, Modifier.fillMaxWidth()) { Label(t.label, modifier = Modifier.padding(12.dp), color = if (t.selected) Tokens.accent else Tokens.text) }
}

@Composable
private fun ProgressBar(fraction: Float) {
    Box(Modifier.fillMaxWidth().height(6.dp).background(Color(0x55FFFFFF))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxHeight().background(Tokens.accent))
    }
}

private fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
