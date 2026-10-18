package app.streamsetu.tv.ui.screens

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.AspectMode
import app.streamsetu.core.playback.EngineKind
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.sync.upcoming
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private enum class PanelKind(val title: String) { TRACKS("Audio & Subtitles"), SPEED("Speed"), PICTURE("Picture"), ENGINE("Player"), MORE("More"), TUNE_PICTURE("Picture tuning"), SOUND("Sound"), SUBLOOK("Subtitle look"), SUBFIND("Subtitles online"), QUALITY("Quality"), CHAPTERS("Chapters"), QUEUE("Up next"), JUMPTO("Go to"), SLEEP("Sleep timer"), JUMP("Jump"), SYNC("Sync"), CHANNELS("Channels"), EPISODES("Episodes") }

private val Ink = Color(0xFFF2F2F2)
private val InkDim = Color(0xB3FFFFFF)

/**
 * The player. Pause and the skip buttons sit in the middle of the picture. At the bottom: the title, a thin seek bar with the times, and a row of plain icons;
 * the icon the remote is on turns white and names itself. Audio and subtitles share one panel, side by side. Everything fades and slides rather than popping.
 *
 * Remote: OK pauses (live: opens the icons); Left and Right skip (live: Left opens the channel list); Up and Down change channel (live); Down in a movie goes to the icons;
 * digits type a channel number; Back asks before leaving.
 */
@Composable
fun PlayerScreen(c: AppContainer, onClose: () -> Unit, onMultiView: () -> Unit = {}, onOpenSeries: (Series) -> Unit = {}, onMinimize: () -> Unit = onClose) {
    val playback = c.playback
    val state by playback.state.collectAsState()
    val current by playback.current.collectAsState()
    val speed by playback.speed.collectAsState()
    val aspect by playback.aspect.collectAsState()
    val resumedFrom by playback.resumedFrom.collectAsState()
    val audio by playback.audioTracks.collectAsState()
    val subs by playback.subtitleTracks.collectAsState()
    val favourites by c.user.favouriteIds().collectAsState(initial = emptySet())
    val item = current
    val live = item?.isLive == true
    val reduced = LocalReducedMotion.current
    fun ms(n: Int) = if (reduced) 0 else n

    var barVisible by remember { mutableStateOf(true) }
    var tick by remember { mutableIntStateOf(0) }
    var panel by remember { mutableStateOf<PanelKind?>(null) }
    var searching by remember { mutableStateOf(false) }
    var searchLiveOnly by remember { mutableStateOf(false) }
    var gotoOpen by remember { mutableStateOf(false) }
    val tuning by playback.tuning.collectAsState()
    val styleNow by playback.subtitleStyle.collectAsState()
    val chapters by playback.chapters.collectAsState()
    val qualities by playback.qualities.collectAsState()
    val nextIn by c.nextEpisodeIn.collectAsState()
    val lined by c.watchQueue.items.collectAsState()
    val appCtx = androidx.compose.ui.platform.LocalContext.current
    val onlineSubs = remember { OnlineSubtitles(appCtx, c.credentials) }
    var controlsFocused by remember { mutableStateOf(false) }
    var seekFlash by remember { mutableStateOf("") }
    var digits by remember { mutableStateOf("") }
    val root = remember { FocusRequester() }
    val controlsFirst = remember { FocusRequester() }
    val failFocus = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    // Match the screen's refresh rate to the video, when the person has turned that on. The mode is given back when the player closes.
    val matchFps by c.settings.matchFrameRate.collectAsState()
    DisposableEffect(matchFps) { onDispose { setDisplayMode(context, null) } }
    LaunchedEffect(matchFps, state, item?.id) {
        if (!matchFps || state != PlaybackState.Playing) return@LaunchedEffect
        repeat(8) {
            val fps = playback.frameRate()
            if (fps > 0f) { setDisplayMode(context, fps); return@LaunchedEffect }
            delay(500)
        }
    }

    fun poke() { barVisible = true; tick++ }
    fun toRoot() { runCatching { root.requestFocus() } }
    fun closePanel() { panel = null; toRoot() }

    BackHandler(enabled = panel != null) { closePanel() }
    // Back with the controls showing hides them first; only a second Back asks about leaving.
    BackHandler(enabled = panel == null && controlsFocused) { toRoot(); barVisible = false }
    // One press of Back asks instead of throwing the player away. A stream that has failed or ended just closes.
    var confirmExit by remember { mutableStateOf(false) }
    val askBeforeLeaving by c.settings.confirmLeavingPlayer.collectAsState()
    BackHandler(enabled = panel == null && !controlsFocused && !confirmExit) {
        if (barVisible) barVisible = false
        else if (askBeforeLeaving && state != PlaybackState.Ended && state !is PlaybackState.Failed) confirmExit = true else onClose()
    }
    LaunchedEffect(Unit) { root.requestFocus() }
    LaunchedEffect(tick, state, controlsFocused, panel) { if (state == PlaybackState.Playing && !controlsFocused && panel == null) { delay(4500); barVisible = false } else barVisible = true }
    LaunchedEffect(seekFlash) { if (seekFlash.isNotEmpty()) { delay(800); seekFlash = "" } }
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
    val barNow by rememberUpdatedState(barVisible)
    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    LaunchedEffect(Unit) { while (true) { position = playback.positionMs; duration = playback.durationMs; delay(if (barNow) 500 else 2000) } }
    var programmes by remember { mutableStateOf<List<EpgProgram>>(emptyList()) }
    LaunchedEffect(item?.id) { programmes = (item as? ChannelPlayable)?.channel?.let { ch -> c.epg.resolve(listOf(ch))[ch.id] }?.let { runCatching { c.epg.upcoming(c.db, it, 4) }.getOrNull() }.orEmpty() }
    // The clock ticks twice a second; only the small pieces that show it redraw. These flags change rarely, so the screen does not redraw with the clock.
    val upNextVisible by remember(item?.id) { derivedStateOf { item is EpisodePlayable && duration > 0 && duration - position in 1..30_000 && c.queue.indexOfFirst { it.id == item.id }.let { it >= 0 && it < c.queue.lastIndex } } }
    val showResumed by remember(resumedFrom) { derivedStateOf { resumedFrom > 0 && position in 1..(resumedFrom + 9000) } }
    val failedOrEnded = state is PlaybackState.Failed || state == PlaybackState.Ended
    val skip = c.settings.seekSeconds.collectAsState().value
    val hasNextEpisode = item is EpisodePlayable && c.queue.indexOfFirst { it.id == item.id }.let { it >= 0 && it < c.queue.lastIndex }

    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(root).focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val code = e.nativeKeyEvent.keyCode
                if (code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_INFO || code == KeyEvent.KEYCODE_BUTTON_Y) { if (panel == null) panel = PanelKind.MORE else closePanel(); return@onPreviewKeyEvent true }
                if (panel != null || controlsFocused || state is PlaybackState.Failed) return@onPreviewKeyEvent false          // the focused list or button takes the keys
                if (live && (code in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 || code in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9)) {
                    digits = (digits + (if (code >= KeyEvent.KEYCODE_NUMPAD_0) code - KeyEvent.KEYCODE_NUMPAD_0 else code - KeyEvent.KEYCODE_0)).takeLast(4); poke(); return@onPreviewKeyEvent true
                }
                when (code) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                        when {
                            upNextVisible -> c.step(+1)
                            !barVisible -> poke()
                            live -> { runCatching { controlsFirst.requestFocus() } }
                            else -> { playback.togglePause(); poke() }
                        }; true
                    }
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { playback.togglePause(); poke(); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { if (!live) { playback.seekBy(skip * 1000L); seekFlash = "+$skip"; poke() } else { poke(); runCatching { controlsFirst.requestFocus() } }; true }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { if (!live) { playback.seekBy(-skip * 1000L); seekFlash = "−$skip"; poke() } else panel = PanelKind.CHANNELS; true }
                    KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP -> { if (live) c.step(if (c.settings.invertChannelKeys.value && code == KeyEvent.KEYCODE_DPAD_UP) -1 else +1); poke(); true }
                    KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN -> { if (live) c.step(if (c.settings.invertChannelKeys.value && code == KeyEvent.KEYCODE_DPAD_DOWN) +1 else -1) else if (barVisible) runCatching { controlsFirst.requestFocus() } else poke(); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> { c.step(+1); poke(); true }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { c.step(-1); poke(); true }
                    else -> false
                }
            },
    ) {
        EngineSurface(c, Modifier.fillMaxSize())
        // A radio station has no picture: its logo and name fill the screen so it does not look like a broken video.
        (item as? ChannelPlayable)?.channel?.takeIf { it.isRadio }?.let { ch ->
            Box(Modifier.fillMaxSize().background(Color(0xFF05080D)), Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 180.dp)
                    Label(ch.name, Tokens.display, Ink, FontWeight.SemiBold)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { Image(Icons.Filled.Radio, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(InkDim)); Label("Radio", Tokens.body, InkDim) }
                }
            }
        }

        StatsOverlay(c, Modifier.align(Alignment.TopEnd).padding(24.dp))

        // ---- The middle: status, or the pause and skip buttons ----
        val busy = state == PlaybackState.Resolving || state == PlaybackState.Buffering || state is PlaybackState.Retrying
        Box(Modifier.align(Alignment.Center)) {
            Crossfade(if (state is PlaybackState.Failed) 2 else if (live && busy) 1 else 0, animationSpec = tween(ms(160)), label = "status") { which ->
                when (which) {
                    1 -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Spinner(); Label(if (state is PlaybackState.Retrying) "Trying again…" else "Loading…", Tokens.small, InkDim)
                    }
                    2 -> (state as? PlaybackState.Failed)?.let { st ->
                        Column(Modifier.background(Color(0xE60A0A0A), RoundedCornerShape(18.dp)).padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Label("This stream did not play", Tokens.title, Ink, FontWeight.SemiBold)
                            Label(st.error.message, Tokens.small, InkDim, maxLines = 3, modifier = Modifier.widthIn(max = 520.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                TvButton("Try Again", { playback.retryNow() }, Modifier.focusRequester(failFocus), primary = true)
                                if (live && c.queue.size > 1) TvButton("Next Channel", { c.step(+1) })
                                TvButton("Close", onClose)
                            }
                        }
                    }
                    else -> if (!live && !failedOrEnded) AnimatedVisibility(barVisible, enter = fadeIn(tween(ms(180))), exit = fadeOut(tween(ms(160)))) {
                        Row(horizontalArrangement = Arrangement.spacedBy(44.dp), verticalAlignment = Alignment.CenterVertically) {
                            Transport(Icons.Filled.Replay, 52, "$skip", flash = seekFlash.startsWith("−"))
                            Box(Modifier.size(76.dp), Alignment.Center) { if (busy) Spinner() else Transport(if (state == PlaybackState.Paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, 76) }
                            Transport(Icons.Filled.Replay, 52, "$skip", mirror = true, flash = seekFlash.startsWith("+"))
                        }
                    }
                }
            }
            if (state == PlaybackState.Ended) Column(horizontalAlignment = Alignment.CenterHorizontally) { Label("The end", Tokens.title, Ink, FontWeight.SemiBold); if (nextIn > 0) Label("Next episode in $nextIn", Tokens.body, InkDim) }
        }
        if (digits.isNotEmpty()) Label(digits, Tokens.display * 1.6f, Ink, FontWeight.Bold, modifier = Modifier.align(Alignment.TopEnd).padding(40.dp))
        AnimatedVisibility(showResumed, Modifier.align(Alignment.TopCenter).padding(top = 40.dp), enter = fadeIn(tween(ms(200))), exit = fadeOut(tween(ms(300)))) {
            Label("Resumed at ${clock(resumedFrom)}", Tokens.small, Ink, modifier = Modifier.background(Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 6.dp))
        }
        AnimatedVisibility(upNextVisible && item is EpisodePlayable, Modifier.align(Alignment.BottomEnd).padding(end = 48.dp, bottom = 150.dp), enter = fadeIn(tween(ms(220))) + slideInVertically(tween(ms(220))) { it / 3 }, exit = fadeOut(tween(ms(160)))) {
            val next = c.queue.getOrNull(c.queue.indexOfFirst { it.id == item?.id } + 1)
            if (next != null) Column(Modifier.background(Color(0xE60A0A0A), RoundedCornerShape(14.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Label("Up next", Tokens.caption, InkDim); Label(next.title, Tokens.row, Ink, FontWeight.SemiBold, modifier = Modifier.widthIn(max = 260.dp)); Label("Press OK to play now", Tokens.caption, InkDim)
            }
        }

        // ---- Top: the title ----
        AnimatedVisibility(barVisible && item != null, Modifier.align(Alignment.TopStart), enter = fadeIn(tween(ms(200))), exit = fadeOut(tween(ms(180)))) {
            Box(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xB3000000), Color.Transparent))).padding(start = 48.dp, end = 48.dp, top = 28.dp, bottom = 40.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Label(if (item is EpisodePlayable) item.series.title else item?.title.orEmpty(), Tokens.display, Ink, FontWeight.Medium)
                    if (item is EpisodePlayable) Label("Season ${item.episode.season}  ·  Episode ${item.episode.number}  ·  ${item.episode.title}", Tokens.small, InkDim)
                }
            }
        }

        // ---- Bottom: bar and icons ----
        AnimatedVisibility(
            barVisible && item != null, Modifier.align(Alignment.BottomStart),
            enter = fadeIn(tween(ms(200))) + slideInVertically(tween(ms(220))) { it / 5 }, exit = fadeOut(tween(ms(180))) + slideOutVertically(tween(ms(180))) { it / 6 },
        ) {
            Column(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xD9000000)))).padding(start = 48.dp, end = 48.dp, top = 48.dp, bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (item is ChannelPlayable) LiveBanner(item.channel, programmes) else SeekBar({ position }, { duration })
                Row(
                    Modifier.fillMaxWidth().onFocusChanged { controlsFocused = it.hasFocus }.onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionUp) { toRoot(); true } else false },
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    var first = true
                    fun req(): Modifier = if (first) { first = false; Modifier.focusRequester(controlsFirst) } else Modifier
                    if (hasNextEpisode) IconControl(Icons.Filled.SkipNext, "Next episode", req()) { c.step(+1) }
                    if (item is EpisodePlayable) IconControl(Icons.Filled.List, "Episodes", req()) { panel = PanelKind.EPISODES }
                    if (live && c.queue.size > 1) IconControl(Icons.Filled.FormatListBulleted, "Channels", req()) { panel = PanelKind.CHANNELS }
                    IconControl(Icons.Filled.Search, "Search", req()) { searching = true }
                    IconControl(Icons.Filled.Subtitles, "Audio & subtitles", req()) { panel = PanelKind.TRACKS }
                    if (!live) IconControl(Icons.Filled.Speed, if (speed == 1f) "Speed" else "Speed ${speed}×", req()) { panel = PanelKind.SPEED }
                    IconControl(Icons.Filled.AspectRatio, "Picture: ${aspect.label}", req()) { panel = PanelKind.PICTURE }
                    IconControl(Icons.Filled.Tune, "Player: ${playback.engineKind?.label ?: "-"}", req()) { panel = PanelKind.ENGINE }
                    IconControl(Icons.Filled.MoreHoriz, "More", req()) { panel = PanelKind.MORE }
                }
            }
        }

        // Search the whole catalog without leaving the player: a channel, movie or episode starts at once; a series opens its page.
        if (searching) androidx.compose.ui.window.Dialog(onDismissRequest = { searching = false; searchLiveOnly = false; toRoot() }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            val first = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(150); runCatching { first.requestFocus() } }
            fun done() { searching = false; searchLiveOnly = false; toRoot() }
            Box(Modifier.fillMaxSize().background(Color(0xF2000000)).padding(horizontal = 56.dp, vertical = 40.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label("Search", Tokens.pageTitle, Ink, FontWeight.Bold)
                    app.streamsetu.tv.ui.screens.search.SearchContent(c, if (searchLiveOnly) setOf(ContentKind.CHANNEL) else setOf(ContentKind.CHANNEL, ContentKind.MOVIE, ContentKind.SERIES), Modifier.fillMaxSize(), entry = first, dropdown = true,
                        onChannel = { ch -> c.play(ChannelPlayable(ch), c.queue); done() },
                        onMovie = { m -> c.play(MoviePlayable(m), listOf(MoviePlayable(m))); done() },
                        onSeries = { sr -> searching = false; onOpenSeries(sr) },
                        onEpisode = { e, sr -> c.play(EpisodePlayable(e, sr), c.queue); done() })
                }
            }
        }

        if (gotoOpen) androidx.compose.ui.window.Dialog(onDismissRequest = { gotoOpen = false }) {
            var text by remember { mutableStateOf("") }
            Column(Modifier.width(420.dp).background(Color(0xFF111111), RoundedCornerShape(16.dp)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Label("Go to time", Tokens.title, Ink, FontWeight.SemiBold)
                Label("Hours:minutes:seconds, for example 1:23:45, or just minutes:seconds.", Tokens.caption, InkDim, maxLines = 2)
                TvTextField(text, { text = it }, "1:23:45", Modifier.fillMaxWidth(), onDone = { PlayerMenus.parseTime(text)?.let { playback.goTo(it); gotoOpen = false; closePanel() } })
                TvButton("Go", { PlayerMenus.parseTime(text)?.let { playback.goTo(it); gotoOpen = false; closePanel() } }, primary = true)
            }
        }

        if (confirmExit) ContextMenu("Stop watching?", item?.title, listOf(
            MenuAction("Continue watching", Icons.Filled.PlayArrow) {},
            MenuAction("Exit the player", Icons.Filled.Close) { onClose() },
        ), onClose = { confirmExit = false; runCatching { root.requestFocus() } })

        // ---- Panels ----
        // Audio and subtitles: one wide panel at the bottom with the two lists side by side.
        AnimatedVisibility(panel == PanelKind.TRACKS, Modifier.align(Alignment.BottomCenter), enter = fadeIn(tween(ms(180))) + slideInVertically(tween(ms(240))) { it / 4 }, exit = fadeOut(tween(ms(160))) + slideOutVertically(tween(ms(160))) { it / 6 }) {
            val firstReq = remember { FocusRequester() }
            LaunchedEffect(Unit) { delay(120); runCatching { firstReq.requestFocus() } }
            Row(Modifier.fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xF2000000), Color(0xF2000000)))).padding(start = 96.dp, end = 96.dp, top = 56.dp, bottom = 40.dp), horizontalArrangement = Arrangement.spacedBy(64.dp)) {
                Column(Modifier.weight(1f)) {
                    Label("Audio", Tokens.heading, InkDim, FontWeight.Medium, modifier = Modifier.padding(bottom = 6.dp))
                    LazyColumn(Modifier.heightIn(max = 230.dp)) {
                        if (audio.isEmpty()) item { Label("Only one audio track", Tokens.small, InkDim) }
                        items(audio, key = { "a" + it.id }) { t -> TextOption(t.label, t.selected, if (t.selected || (audio.none { it.selected } && t === audio.first())) Modifier.focusRequester(firstReq) else Modifier) { playback.selectAudio(t.id); closePanel() } }
                    }
                }
                Column(Modifier.weight(1f)) {
                    Label("Subtitles", Tokens.heading, InkDim, FontWeight.Medium, modifier = Modifier.padding(bottom = 6.dp))
                    LazyColumn(Modifier.heightIn(max = 230.dp)) {
                        item { TextOption("Off", subs.none { it.selected }, Modifier) { playback.selectSubtitle(null); closePanel() } }
                        items(subs, key = { "s" + it.id }) { t -> TextOption(t.label, t.selected, Modifier) { playback.selectSubtitle(t.id); closePanel() } }
                    }
                }
            }
        }
        // Everything else: a narrow sheet from the right edge.
        AnimatedVisibility(panel != null && panel != PanelKind.TRACKS, Modifier.align(Alignment.CenterEnd), enter = fadeIn(tween(ms(180))) + slideInHorizontally(tween(ms(240))) { it / 3 }, exit = fadeOut(tween(ms(160))) + slideOutHorizontally(tween(ms(160))) { it / 4 }) {
            val kind = panel ?: return@AnimatedVisibility
            val selectedReq = remember(kind) { FocusRequester() }
            LaunchedEffect(kind) { delay(120); runCatching { selectedReq.requestFocus() } }
            Column(Modifier.fillMaxHeight().width(360.dp).background(Brush.horizontalGradient(listOf(Color.Transparent, Color(0xF2000000), Color(0xF2000000)))).padding(start = 72.dp, end = 40.dp, top = 40.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Label(kind.title, Tokens.title, Ink, FontWeight.Medium, modifier = Modifier.padding(bottom = 6.dp))
                LazyColumn {
                    when (kind) {
                        PanelKind.SPEED -> items(listOf(0.25f, 0.5f, 0.75f, 1f, 1.1f, 1.25f, 1.5f, 1.75f, 2f, 3f), key = { "v$it" }) { v -> TextOption(if (v == 1f) "Normal" else "${v}×", v == speed, if (v == speed) Modifier.focusRequester(selectedReq) else Modifier) { playback.setSpeed(v); closePanel() } }
                        PanelKind.PICTURE -> items(AspectMode.entries, key = { "p" + it.name }) { m -> TextOption(m.label, m == aspect, if (m == aspect) Modifier.focusRequester(selectedReq) else Modifier) { playback.setAspect(m); closePanel() } }
                        PanelKind.ENGINE -> items(playback.available.toList(), key = { "e" + it.name }) { k -> TextOption(k.label, k == playback.engineKind, if (k == playback.engineKind) Modifier.focusRequester(selectedReq) else Modifier, if (k == EngineKind.MPV) "MKV, AVI and unusual formats" else "HLS, MP4 and transport streams") { playback.switchEngine(k); closePanel() } }
                        PanelKind.CHANNELS -> { item { TextOption("Search channels…", false, Modifier, "Type a name") { searchLiveOnly = true; searching = true; panel = null } }; items(c.queue.filterIsInstance<ChannelPlayable>(), key = { "c" + it.id }) { ch -> TextOption("${ch.channel.number?.let { "$it  " } ?: ""}${ch.channel.name}", ch.id == item?.id, if (ch.id == item?.id) Modifier.focusRequester(selectedReq) else Modifier) { c.play(ch, c.queue); closePanel() } } }
                        PanelKind.EPISODES -> {
                            val eps = c.queue.filterIsInstance<EpisodePlayable>().filter { (item as? EpisodePlayable)?.episode?.season == it.episode.season }
                            items(eps, key = { "ep" + it.id }) { ep -> TextOption("${ep.episode.number}.  ${ep.episode.title}", ep.id == item?.id, if (ep.id == item?.id) Modifier.focusRequester(selectedReq) else Modifier) { c.play(ep, c.queue); closePanel() } }
                        }
                        PanelKind.MORE -> {
                            if (live) item { TextOption("Multi-View", false, Modifier) { onMultiView() } }
                            if (!live && playback.introEndMs() != null) item { TextOption("Skip intro", false, Modifier.focusRequester(selectedReq)) { playback.skipIntro(); closePanel() } }
                            if (!live && lined.isNotEmpty()) item { TextOption("Up next: ${lined.size} in the queue", false, Modifier) { panel = PanelKind.QUEUE } }
                            if (!live && playback.recapEndMs() != null) item { TextOption("Skip recap", false, Modifier.focusRequester(selectedReq)) { playback.skipRecap(); closePanel() } }
                            if (!live && playback.creditsShowing()) item { TextOption("Skip credits", false, Modifier.focusRequester(selectedReq)) { if (hasNextEpisode) { playback.noteCreditsSkip(); c.step(+1) } else playback.skipCreditsToEnd(); closePanel() } }
                            if (!live && resumedFrom > 0) item { TextOption("Start over", false, Modifier.focusRequester(selectedReq)) { playback.startOver(); closePanel() } }
                            item { val end by playback.sleepEndsAt.collectAsState(); TextOption("Sleep timer" + if (end > 0) ": " + ((end - System.currentTimeMillis()) / 60_000 + 1) + " min left" else "", false, if (live || resumedFrom <= 0) Modifier.focusRequester(selectedReq) else Modifier) { panel = PanelKind.SLEEP } }
                            if (!live) item { TextOption("Jump", false, Modifier) { panel = PanelKind.JUMP } }
                            item { TextOption("Sync audio & subtitles", false, Modifier) { panel = PanelKind.SYNC } }
                            item { TextOption("Picture tuning", false, Modifier, "Brightness, contrast, saturation, decoding") { panel = PanelKind.TUNE_PICTURE } }
                            item { TextOption("Sound", false, Modifier, "Volume boost, even out loudness") { panel = PanelKind.SOUND } }
                            item { TextOption("Subtitle look", false, Modifier, "Size, colour, position, background") { panel = PanelKind.SUBLOOK } }
                            item { TextOption("Find subtitles online", false, Modifier, "From OpenSubtitles, with your free key") { panel = PanelKind.SUBFIND } }
                            if (qualities.isNotEmpty()) item { TextOption("Quality", false, Modifier, "Choose the resolution") { panel = PanelKind.QUALITY } }
                            if (!live && chapters.isNotEmpty()) item { TextOption("Chapters", false, Modifier) { panel = PanelKind.CHAPTERS } }
                            if (!live) item { TextOption("Go to time…", false, Modifier, "Type an exact time, or jump by tenths") { panel = PanelKind.JUMPTO } }
                            item { var v by remember { mutableStateOf(playback.rememberPerTitle) }; TextOption("Remember settings for this title: " + if (v) "on" else "off", false, Modifier, "Audio, subtitles, speed, picture, sound") { playback.rememberPerTitle = !v; v = !v } }
                            if (item is EpisodePlayable) item { val auto by c.settings.playNextAutomatically.collectAsState(); TextOption("Play next episode by itself: " + if (auto) "on" else "off", false, Modifier) { c.settings.setPlayNext(!auto) } }
                            item { val sk by c.settings.seekSeconds.collectAsState(); TextOption("Skip length: $sk seconds", false, Modifier, "Press to change: 5, 10, 15, 30, 85") { c.settings.setSeekSeconds(listOf(5, 10, 15, 30, 85).let { l -> l[(l.indexOf(sk) + 1).mod(l.size)] }) } }
                            if (live && item != null) item { TextOption(if (item.id in favourites) "Remove from favorites" else "Add to favorites", false, Modifier) { scope.launch { c.user.setFavourite(item.id, ContentKind.CHANNEL, item.id !in favourites) }; closePanel() } }
                            if (live) (item as? ChannelPlayable)?.let { cp -> programmes.firstOrNull { it.startMs > System.currentTimeMillis() + 2 * 60_000L }?.let { nx -> item { TextOption("Remind me: " + nx.title, false, Modifier, "A notification when it starts") { scope.launch { app.streamsetu.tv.Reminders.schedule(c, context, cp.channel, nx) }; closePanel() } } } }
                            if (live && c.previousLive != null) item { TextOption("Last channel", false, Modifier) { c.lastChannel(); closePanel() } }
                            item { val on by c.settings.showStreamInfo.collectAsState(); TextOption("Stream information: " + if (on) "on" else "off", false, Modifier) { c.settings.setShowStreamInfo(!on); closePanel() } }
                            if (android.os.Build.VERSION.SDK_INT >= 26) item { TextOption("Picture in Picture", false, Modifier) { closePanel(); (context as? android.app.Activity)?.enterPictureInPictureMode(android.app.PictureInPictureParams.Builder().build()) } }
                            item { TextOption("Keep playing while I browse", false, Modifier, "The picture closes, the sound stays. Menu or Info brings it back.") { c.playback.setMinimized(true); onMinimize() } }
                            item { TextOption("Close player", false, Modifier) { onClose() } }
                        }
                        PanelKind.TUNE_PICTURE -> items(PlayerMenus.picture(playback, tuning)) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); if (!e.keepOpen) closePanel() } }
                        PanelKind.SOUND -> items(PlayerMenus.sound(playback, tuning)) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); if (!e.keepOpen) closePanel() } }
                        PanelKind.SUBLOOK -> items(PlayerMenus.subtitleStyle(playback, styleNow ?: playback.currentSubtitleStyle())) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); if (!e.keepOpen) closePanel() } }
                        PanelKind.QUALITY -> items(PlayerMenus.quality(playback, qualities)) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); if (!e.keepOpen) closePanel() } }
                        PanelKind.QUEUE -> {
                            items(lined) { t -> TextOption(t.title, false, Modifier, "Press OK to take it out of the queue") { c.watchQueue.remove(t.id) } }
                            item { TextOption("Clear the queue", false, Modifier) { c.watchQueue.clear(); closePanel() } }
                        }
                        PanelKind.CHAPTERS -> items(PlayerMenus.chapters(playback, chapters)) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); if (!e.keepOpen) closePanel() } }
                        PanelKind.JUMPTO -> {
                            item { TextOption("Type a time…", false, Modifier.focusRequester(selectedReq), "For example 1:23:45") { gotoOpen = true } }
                            items(PlayerMenus.jumpToPoints(playback)) { e -> TextOption(e.title, e.selected, Modifier, e.detail) { e.action(); closePanel() } }
                        }
                        PanelKind.SUBFIND -> item { OnlineSubtitlesPanel(onlineSubs, playback, item, c.settings.subtitleLanguage.collectAsState().value) { closePanel() } }
                        PanelKind.SLEEP -> {
                            items(listOf(0, 15, 30, 45, 60, 90, 120), key = { "z$it" }) { m -> val end by playback.sleepEndsAt.collectAsState(); TextOption(if (m == 0) (if (end > 0) "Turn off" else "Off") else "$m minutes", m == 0 && end == 0L, if (m == 0) Modifier.focusRequester(selectedReq) else Modifier) { playback.startSleepTimer(m); closePanel() } }
                        }
                        PanelKind.JUMP -> {
                            items(listOf(-600_000L to "Back 10 minutes", -60_000L to "Back 1 minute", -10_000L to "Back 10 seconds", 10_000L to "Forward 10 seconds", 60_000L to "Forward 1 minute", 600_000L to "Forward 10 minutes"), key = { "j${it.first}" }) { (d, label) ->
                                TextOption(label, false, if (d == -600_000L) Modifier.focusRequester(selectedReq) else Modifier) { playback.seekBy(d); closePanel() }
                            }
                            item { TextOption("Start over", false, Modifier) { playback.startOver(); closePanel() } }
                        }
                        PanelKind.SYNC -> {
                            item { val sd by playback.subtitleDelayMs.collectAsState(); TextOption("Subtitles later  (now ${sd} ms)", false, Modifier.focusRequester(selectedReq)) { playback.setSubtitleDelay(sd + 250) } }
                            item { val sd by playback.subtitleDelayMs.collectAsState(); TextOption("Subtitles earlier", false, Modifier) { playback.setSubtitleDelay(sd - 250) } }
                            item { val ad by playback.audioDelayMs.collectAsState(); TextOption("Audio later  (now ${ad} ms)", false, Modifier) { playback.setAudioDelay(ad + 100) } }
                            item { val ad by playback.audioDelayMs.collectAsState(); TextOption("Audio earlier", false, Modifier) { playback.setAudioDelay(ad - 100) } }
                            item { TextOption("Reset both", false, Modifier) { playback.setSubtitleDelay(0); playback.setAudioDelay(0) } }
                        }
                        PanelKind.TRACKS -> {}
                    }
                }
            }
        }
    }
}

/** An icon with no box around it. When the remote is on it, it fills white and says what it is, under it. */
@Composable
private fun IconControl(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val labelAlpha by animateFloatAsState(if (focused) 1f else 0f, tween(140), label = "controlLabel")
    Column(Modifier.width(64.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Focusable(onClick, modifier.size(46.dp), shape = CircleShape, container = Color.Transparent, focusedContainer = Color.White, scaleOnFocus = 1.0f, onFocus = { focused = it }) { f ->
            Box(Modifier.fillMaxSize(), Alignment.Center) { Image(icon, label, Modifier.size(24.dp), colorFilter = ColorFilter.tint(if (f) Color.Black else Ink)) }
        }
        Label(label, Tokens.caption, Ink, FontWeight.Medium, maxLines = 2, modifier = Modifier.padding(top = 3.dp).graphicsLayer { alpha = labelAlpha })
    }
}

/** A plain line of text in a panel: bright when the remote is on it, a small tick when it is the current choice. */
@Composable
private fun TextOption(label: String, selected: Boolean, modifier: Modifier, detail: String? = null, onClick: () -> Unit) {
    Focusable(onClick, modifier.fillMaxWidth(), shape = RoundedCornerShape(8.dp), container = Color.Transparent, focusedContainer = Color(0x2EFFFFFF), scaleOnFocus = 1.0f) { f ->
        Row(Modifier.padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.width(18.dp)) { if (selected) Image(Icons.Filled.Check, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(Ink)) }
            Column {
                Label(label, Tokens.heading, if (f || selected) Ink else InkDim, if (selected) FontWeight.SemiBold else FontWeight.Normal)
                if (detail != null) Label(detail, Tokens.caption, InkDim)
            }
        }
    }
}

/** The seek bar: a thin track, the played part in white, a small round handle, the time played on the left and the time left on the right. */
@Composable
private fun SeekBar(positionOf: () -> Long, durationOf: () -> Long) {
    val position = positionOf(); val duration = durationOf()
    val frac = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Label(clock(position), Tokens.small, Ink, modifier = Modifier.widthIn(min = 50.dp))
        BoxWithConstraints(Modifier.weight(1f).height(18.dp), contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(4.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp)))
            Box(Modifier.fillMaxWidth(frac).height(4.dp).background(Color.White, RoundedCornerShape(2.dp)))
            Box(Modifier.graphicsLayer { translationX = (maxWidth * frac - 6.dp).toPx() }.size(12.dp).background(Color.White, CircleShape))
        }
        Label("−" + clock((duration - position).coerceAtLeast(0)), Tokens.small, InkDim, modifier = Modifier.widthIn(min = 56.dp))
    }
}

/** A button in the middle of the picture. No box; the icon is white with a soft dark disc behind it so it shows on any picture. */
@Composable
private fun Transport(icon: ImageVector, size: Int, label: String? = null, mirror: Boolean = false, flash: Boolean = false) {
    val scale by animateFloatAsState(if (flash) 1.18f else 1f, tween(Motion.FOCUS), label = "transport")
    Box(Modifier.size(size.dp).graphicsLayer { scaleX = scale; scaleY = scale }.clip(CircleShape).background(Color(0x33000000)), Alignment.Center) {
        Image(icon, null, Modifier.size((size * 0.62f).dp).graphicsLayer { if (mirror) scaleX = -1f }, colorFilter = ColorFilter.tint(Color.White))
        if (label != null) Label(label, Tokens.small, Color.White, FontWeight.Bold)
    }
}

/** A live channel: logo, number, name, a small red LIVE mark, what is on now with a thin progress bar, and what is next. No box. */
@Composable
private fun LiveBanner(ch: Channel, programmes: List<EpgProgram>) {
    val time = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }
    val now = System.currentTimeMillis()
    val current = programmes.firstOrNull { it.isLive(now) }
    val upcoming = programmes.filter { it.startMs > now }.take(2)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        ChannelLogo(ch.logoUrl, ch.name, 48.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ch.number?.let { Label("$it", Tokens.heading, InkDim) }
                Label(ch.name, Tokens.title, Ink, FontWeight.SemiBold, modifier = Modifier.weight(1f, fill = false))
                Box(Modifier.size(7.dp).background(Color(0xFFE5484D), CircleShape)); Label("Live", Tokens.caption, InkDim)
            }
            if (current != null) {
                Label("${current.title}   ${time.format(Date(current.startMs))} – ${time.format(Date(current.endMs))}", Tokens.small, Ink)
                val frac = ((now - current.startMs).toFloat() / (current.endMs - current.startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
                Box(Modifier.width(320.dp).height(3.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(Color.White, RoundedCornerShape(2.dp))) }
            }
            upcoming.forEachIndexed { i, n -> Label((if (i == 0) "Next" else "Then") + "  ·  ${time.format(Date(n.startMs))}  ${n.title}", Tokens.caption, InkDim) }
        }
    }
}

private fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}


/** Subtitles from OpenSubtitles for what is playing: a list to pick from, or a sentence about what is missing. */
@Composable
private fun OnlineSubtitlesPanel(client: OnlineSubtitles, playback: app.streamsetu.core.playback.PlaybackController, item: Playable?, language: String, onDone: () -> Unit) {
    var hits by remember { mutableStateOf<List<OnlineSubtitles.Hit>?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val title = (item as? EpisodePlayable)?.series?.title ?: item?.title.orEmpty()
    val year = (item as? MoviePlayable)?.movie?.year
    LaunchedEffect(item?.id) {
        if (!client.configured) { message = "Add your free OpenSubtitles key, account name and password in Settings, Subtitles & Accessibility."; return@LaunchedEffect }
        runCatching { client.search(title, year, language) }.onSuccess { hits = it; if (it.isEmpty()) message = "No subtitles found for this title." }.onFailure { message = it.message ?: "The search did not work." }
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        message?.let { Label(it, Tokens.body, InkDim, maxLines = 5) }
        if (message == null && hits == null) Label("Searching…", Tokens.body, InkDim)
        hits?.forEach { h ->
            TextOption(h.label, false, Modifier) {
                scope.launch { message = "Downloading…"; runCatching { client.download(h) }.onSuccess { playback.addSubtitle(it, "Online"); onDone() }.onFailure { message = it.message ?: "That did not work." } }
            }
        }
    }
}

/** Asks the TV to run at the refresh rate that suits a video of [fps] frames a second; null gives the screen back to the system. Does nothing where the TV has no suitable mode. */
@Suppress("DEPRECATION")
private fun setDisplayMode(context: android.content.Context, fps: Float?) {
    var ctx = context
    while (ctx is android.content.ContextWrapper && ctx !is android.app.Activity) ctx = ctx.baseContext
    val activity = ctx as? android.app.Activity ?: return
    val display = activity.windowManager.defaultDisplay ?: return
    val attrs = activity.window.attributes
    if (fps == null) { if (attrs.preferredDisplayModeId != 0) { attrs.preferredDisplayModeId = 0; activity.window.attributes = attrs }; return }
    fun mode(m: android.view.Display.Mode) = app.streamsetu.core.playback.DisplayMode(m.modeId, m.physicalWidth, m.physicalHeight, m.refreshRate)
    val current = display.mode?.let(::mode) ?: return
    val pick = app.streamsetu.core.playback.DisplayModes.best(display.supportedModes.map(::mode), current, fps) ?: return
    attrs.preferredDisplayModeId = pick.id
    activity.window.attributes = attrs
}
