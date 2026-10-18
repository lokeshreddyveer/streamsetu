package app.streamsetu.tv.ui.phone

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.AspectMode
import app.streamsetu.core.playback.EngineKind
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.core.sync.upcoming
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.PlayerMenus
import app.streamsetu.tv.ui.components.StatsOverlay
import app.streamsetu.tv.ui.components.EngineSurface
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Spinner
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.layout.onSizeChanged
import kotlin.math.abs

private enum class Panel { SEARCH, SEARCH_LIVE, TUNE, SOUND, SUBLOOK, SUBFIND, QUALITY, CHAPTERS, QUEUE, JUMPTO, AUDIO, SUBS, SPEED, PICTURE, ENGINE, EPISODES, CHANNELS, MORE, SLEEP, SYNC, CAST }

private val Ink = Color(0xFFF2F2F2)
private val InkDim = Color(0xB3FFFFFF)

private fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/**
 * The player for a touch screen. Tap the picture to show or hide the controls. Double-tap the left or right side to skip back or forward. Drag along the bar to seek.
 * Swipe up or down on the left half for brightness and on the right half for volume. The bottom buttons open audio, subtitles, speed, picture and the rest as sheets.
 * Turn the phone to fill the screen; the controls follow.
 */
@Composable
fun PhonePlayer(c: AppContainer, onClose: () -> Unit, onMinimize: () -> Unit = onClose, onMultiView: () -> Unit = {}, onOpenSeries: (Series) -> Unit = {}) {
    val playback = c.playback
    val state by playback.state.collectAsState()
    val current by playback.current.collectAsState()
    val speed by playback.speed.collectAsState()
    val aspect by playback.aspect.collectAsState()
    val resumedFrom by playback.resumedFrom.collectAsState()
    val audio by playback.audioTracks.collectAsState()
    val subs by playback.subtitleTracks.collectAsState()
    val favourites by c.user.favouriteIds().collectAsState(initial = emptySet())
    val castState by c.cast.state.collectAsState()
    val casting = castState as? app.streamsetu.tv.CastState.Casting
    val castScope = rememberCoroutineScope()
    val sleepAt by playback.sleepEndsAt.collectAsState()
    val subDelay by playback.subtitleDelayMs.collectAsState()
    val audioDelay by playback.audioDelayMs.collectAsState()
    val item = current
    val live = item?.isLive == true
    val skip = c.settings.seekSeconds.collectAsState().value
    val context = LocalContext.current
    val view = LocalView.current

    var controls by remember { mutableStateOf(true) }
    var tick by remember { mutableIntStateOf(0) }
    var panel by remember { mutableStateOf<Panel?>(null) }
    var gotoOpen by remember { mutableStateOf(false) }
    val tuning by playback.tuning.collectAsState()
    val styleNow by playback.subtitleStyle.collectAsState()
    val chapters by playback.chapters.collectAsState()
    val qualities by playback.qualities.collectAsState()
    val nextIn by c.nextEpisodeIn.collectAsState()
    val lined by c.watchQueue.items.collectAsState()
    val onlineSubs = remember { app.streamsetu.tv.ui.screens.OnlineSubtitles(context, c.credentials) }
    var subHits by remember { mutableStateOf<List<app.streamsetu.tv.ui.screens.OnlineSubtitles.Hit>?>(null) }
    var subMessage by remember { mutableStateOf<String?>(null) }
    val subScope = rememberCoroutineScope()
    var epgNext by remember { mutableStateOf<app.streamsetu.core.model.EpgProgram?>(null) }
    LaunchedEffect(item?.id) {
        epgNext = (item as? ChannelPlayable)?.channel?.let { ch -> c.epg.resolve(listOf(ch))[ch.id] }?.let { id -> runCatching { c.epg.upcoming(c.db, id, 4) }.getOrNull() }
            ?.firstOrNull { it.startMs > System.currentTimeMillis() + 2 * 60_000L }
    }
    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    var dragFrac by remember { mutableStateOf<Float?>(null) }
    var hint by remember { mutableStateOf("") }
    var flash by remember { mutableStateOf<Int?>(null) }   // -1 left, +1 right

    fun poke() { controls = true; tick++ }
    // Opening the player brings the picture back after the mini player; the player closes itself when the sleep timer (or anything else) stops playback.
    LaunchedEffect(Unit) { playback.setMinimized(false) }
    LaunchedEffect(item) { if (item == null) onClose() }
    val pickSubtitle = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val name = uri.lastPathSegment?.substringAfterLast('/')?.substringAfterLast(':') ?: "subtitles.srt"
            val file = java.io.File(context.cacheDir, "subtitles").also { it.mkdirs() }.let { dir -> java.io.File(dir, name.ifBlank { "subtitles.srt" }) }
            val ok = runCatching { context.contentResolver.openInputStream(uri)?.use { i -> file.outputStream().use { o -> i.copyTo(o) } }; true }.getOrDefault(false)
            val added = ok && playback.addSubtitle("file://" + file.absolutePath, file.nameWithoutExtension)
            android.widget.Toast.makeText(context, if (added) "Subtitles added" else "Those subtitles could not be loaded", android.widget.Toast.LENGTH_SHORT).show()
        }
    }
    fun seekTo(ms: Long) { playback.seekBy(ms.coerceIn(0, duration.takeIf { it > 0 } ?: Long.MAX_VALUE) - playback.positionMs) }

    // Full screen: hide the system bars, keep the screen on. Both are put back when the player closes.
    DisposableEffect(Unit) {
        val window = (context as? Activity)?.window
        val ctl = window?.let { WindowCompat.getInsetsController(it, view) }
        ctl?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        ctl?.hide(WindowInsetsCompat.Type.systemBars())
        view.keepScreenOn = true
        onDispose {
            ctl?.show(WindowInsetsCompat.Type.systemBars())
            view.keepScreenOn = false
            window?.attributes = window.attributes.also { it.screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
        }
    }
    LaunchedEffect(tick, state, controls, panel, dragFrac) { if (state == PlaybackState.Playing && panel == null && dragFrac == null && controls) { delay(3500); controls = false } else if (state != PlaybackState.Playing) controls = true }
    LaunchedEffect(hint) { if (hint.isNotEmpty()) { delay(900); hint = "" } }
    LaunchedEffect(flash) { if (flash != null) { delay(450); flash = null } }
    val controlsNow by rememberUpdatedState(controls)
    LaunchedEffect(Unit) { while (true) { position = playback.positionMs; duration = playback.durationMs; delay(if (controlsNow) 400 else 1500) } }

    val busy = state == PlaybackState.Resolving || state == PlaybackState.Buffering || state is PlaybackState.Retrying
    val failed = state is PlaybackState.Failed
    val hasNext = item is EpisodePlayable && c.queue.indexOfFirst { it.id == item.id }.let { it >= 0 && it < c.queue.lastIndex }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .semantics { onClick(label = if (controls) "Hide the controls" else "Show the controls") { if (controls) controls = false else poke(); true } }
            .pointerInput(live, skip) {
                detectTapGestures(
                    onTap = { if (controls) controls = false else poke() },
                    onDoubleTap = { o ->
                        if (live) return@detectTapGestures
                        val right = o.x > size.width / 2
                        playback.seekBy((if (right) skip else -skip) * 1000L); flash = if (right) 1 else -1; poke()
                    },
                )
            }
            .pointerInput(Unit) {
                // Left half: brightness. Right half: volume. A drag of the full height changes it by about the full range.
                var onLeft = true
                var acc = 0f
                detectVerticalDragGestures(
                    onDragStart = { o -> onLeft = o.x < size.width / 2; acc = 0f },
                    onVerticalDrag = { change, dy ->
                        change.consume()
                        acc += -dy / size.height
                        if (abs(acc) < 0.02f) return@detectVerticalDragGestures
                        val delta = acc; acc = 0f
                        if (onLeft) {
                            val w = (context as? Activity)?.window ?: return@detectVerticalDragGestures
                            val now = w.attributes.screenBrightness.takeIf { it >= 0f } ?: 0.5f
                            val v = (now + delta).coerceIn(0.02f, 1f)
                            w.attributes = w.attributes.also { it.screenBrightness = v }
                            hint = "Brightness  ${(v * 100).toInt()}%"
                        } else {
                            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                            val next = (cur + (delta * max * 1.3f).let { if (abs(it) < 1f) (if (it > 0) 1f else -1f) else it }).toInt().coerceIn(0, max)
                            am.setStreamVolume(AudioManager.STREAM_MUSIC, next, 0)
                            hint = "Volume  ${if (max > 0) next * 100 / max else 0}%"
                        }
                    },
                )
            },
    ) {
        EngineSurface(c, Modifier.fillMaxSize())

        // Casting: the picture is on the other screen; this is its remote control.
        if (casting != null) Column(Modifier.fillMaxSize().background(Color(0xF2050505)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.Filled.Cast, Tokens.accent, 56.dp)
            Label("Casting to ${casting.device}", Ph.heading, Ink, FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp))
            Label(item?.title.orEmpty(), Ph.small, InkDim, modifier = Modifier.padding(top = 4.dp))
            Row(Modifier.padding(top = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PillButton(if (casting.playing) "Pause" else "Play", { c.cast.togglePause() }, primary = true, icon = if (casting.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow)
                PillButton("Stop casting", { val at = c.cast.positionMs(); c.cast.stop(); if (!live && at > 0) playback.seekBy(at - playback.positionMs) }, icon = Icons.Filled.Close)
            }
            PillButton("Back", onClose, Modifier.padding(top = 12.dp))
        }

        // Double-tap feedback.
        AnimatedVisibility(flash != null, Modifier.align(if (flash == 1) Alignment.CenterEnd else Alignment.CenterStart).padding(horizontal = 56.dp), enter = fadeIn(), exit = fadeOut()) {
            Column(Modifier.clip(CircleShape).background(Color(0x66000000)).padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(if (flash == 1) Icons.Filled.Forward10 else Icons.Filled.Replay10, Color.White, 34.dp)
                Label("${if (flash == 1) "+" else "−"}$skip s", Ph.small, Color.White, FontWeight.SemiBold)
            }
        }
        // The opening of an episode: one tap jumps past it (the length is learned from the person's own skips in the series).
        val skipLabel = remember(position, item) {
            when {
                live -> null
                playback.recapEndMs() != null -> "Skip recap"
                playback.introEndMs() != null -> "Skip intro"
                playback.creditsShowing() -> "Skip credits"
                else -> null
            }
        }
        if (skipLabel != null && !failed) PillButton(skipLabel, {
            when (skipLabel) {
                "Skip recap" -> playback.skipRecap()
                "Skip intro" -> playback.skipIntro()
                else -> if (hasNext) { playback.noteCreditsSkip(); c.step(+1) } else playback.skipCreditsToEnd()
            }
            poke()
        }, Modifier.align(Alignment.BottomEnd).windowInsetsPadding(WindowInsets.systemBars).padding(end = 16.dp, bottom = if (controls) 132.dp else 36.dp), icon = Icons.Filled.SkipNext)
        if (hint.isNotEmpty()) Label(hint, Ph.body, Color.White, FontWeight.SemiBold, modifier = Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(top = 64.dp).background(Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 16.dp, vertical = 8.dp))
        if (resumedFrom > 0 && position in 1..(resumedFrom + 8000) && !controls) Label("Resumed at ${clock(resumedFrom)}", Ph.small, Ink, modifier = Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(top = 16.dp).background(Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 6.dp))

        // A radio station has no picture.
        (item as? ChannelPlayable)?.channel?.takeIf { it.isRadio }?.let { ch ->
            Column(Modifier.fillMaxSize().background(Color(0xFF05080D)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                app.streamsetu.tv.ui.components.ChannelLogo(ch.logoUrl, ch.name, 140.dp)
                Label(ch.name, Ph.title, Ink, FontWeight.SemiBold, modifier = Modifier.padding(top = 14.dp))
                Label("Radio", Ph.small, InkDim)
            }
        }

        // Loading or failed.
        Box(Modifier.align(Alignment.Center)) {
            Crossfade(if (failed) 2 else if (busy && (live || !controls)) 1 else 0, label = "status") { which ->
                when (which) {
                    1 -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) { Spinner(); Label(if (state is PlaybackState.Retrying) "Trying again…" else "Loading…", Ph.small, InkDim) }
                    2 -> (state as? PlaybackState.Failed)?.let { st ->
                        Column(Modifier.padding(24.dp).background(Color(0xE60A0A0A), RoundedCornerShape(18.dp)).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Label("This stream did not play", Ph.heading, Ink, FontWeight.SemiBold)
                            Label(st.error.message, Ph.small, InkDim, maxLines = 4)
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                PillButton("Try again", { playback.retryNow() }, primary = true)
                                if (live && c.queue.size > 1) PillButton("Next", { c.step(+1) })
                                PillButton("Close", onClose)
                            }
                        }
                    }
                    else -> {}
                }
            }
        }

        AnimatedVisibility(controls && !failed, enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color(0xB3000000), 0.3f to Color(0x33000000), 0.7f to Color(0x33000000), 1f to Color(0xCC000000))))
                // Top: back, title, more.
                Row(Modifier.align(Alignment.TopStart).fillMaxWidth().windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout)).padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconTap(Icons.Filled.ArrowBack, "Back", onClose)
                    IconTap(Icons.Filled.KeyboardArrowDown, "Minimize", onMinimize)
                    Column(Modifier.weight(1f).padding(horizontal = 6.dp)) {
                        Label(if (item is EpisodePlayable) item.series.title else item?.title.orEmpty(), Ph.body, Ink, FontWeight.SemiBold)
                        if (item is EpisodePlayable) Label("Season ${item.episode.season}  ·  Episode ${item.episode.number}  ·  ${item.episode.title}", Ph.caption, InkDim)
                    }
                    if (live && item != null) IconTap(if (item.id in favourites) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Favorite", { c.appScope.launch { c.user.setFavourite(item.id, ContentKind.CHANNEL, item.id !in favourites) } }, tint = if (item.id in favourites) Tokens.gold else Color.White)
                    IconTap(Icons.Filled.Search, "Search", { panel = Panel.SEARCH; poke() })
                    IconTap(Icons.Filled.MoreVert, "More", { panel = Panel.MORE; poke() })
                }
                // Middle: skip back, play or pause, skip forward.
                Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(34.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (live) { if (c.queue.size > 1) BigButton(Icons.Filled.SkipPrevious, 52) { c.step(-1); poke() } }
                    else BigButton(Icons.Filled.Replay10, 52) { playback.seekBy(-skip * 1000L); flash = -1; poke() }
                    Box(Modifier.size(72.dp), Alignment.Center) { if (busy) Spinner() else BigButton(if (state == PlaybackState.Paused || state == PlaybackState.Ended) Icons.Filled.PlayArrow else Icons.Filled.Pause, 72) { playback.togglePause(); poke() } }
                    if (live) { if (c.queue.size > 1) BigButton(Icons.Filled.SkipNext, 52) { c.step(+1); poke() } }
                    else BigButton(Icons.Filled.Forward10, 52) { playback.seekBy(skip * 1000L); flash = 1; poke() }
                }
                // Bottom: the bar and the buttons.
                Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout)).padding(horizontal = 12.dp, vertical = 4.dp)) {
                    if (live) Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Box(Modifier.size(8.dp).background(Color(0xFFE5484D), CircleShape)); Label("Live", Ph.small, InkDim)
                    } else {
                        val frac = dragFrac ?: if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Label(clock(if (dragFrac != null) (dragFrac!! * duration).toLong() else position), Ph.small, Ink, modifier = Modifier.widthIn(min = 46.dp))
                            SeekBar(frac, Modifier.weight(1f), onStart = { dragFrac = frac }, onChange = { dragFrac = it; poke() }, onEnd = { f -> seekTo((f * duration).toLong()); dragFrac = null; poke() })
                            Label("−" + clock((duration - position).coerceAtLeast(0)), Ph.small, InkDim, modifier = Modifier.widthIn(min = 52.dp))
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                        if (hasNext) IconTap(Icons.Filled.SkipNext, "Next episode", { c.step(+1) })
                        if (item is EpisodePlayable) IconTap(Icons.Filled.List, "Episodes", { panel = Panel.EPISODES; poke() })
                        if (live && c.queue.size > 1) IconTap(Icons.Filled.FormatListBulleted, "Channels", { panel = Panel.CHANNELS; poke() })
                        IconTap(Icons.Filled.Audiotrack, "Audio", { panel = Panel.AUDIO; poke() })
                        IconTap(Icons.Filled.Subtitles, "Subtitles", { panel = Panel.SUBS; poke() })
                        if (!live) IconTap(Icons.Filled.Speed, "Speed", { panel = Panel.SPEED; poke() })
                        IconTap(Icons.Filled.AspectRatio, "Picture", { panel = Panel.PICTURE; poke() })
                        IconTap(Icons.Filled.Tune, "Player", { panel = Panel.ENGINE; poke() })
                    }
                }
            }
        }
    }

    StatsOverlay(c, Modifier.windowInsetsPadding(WindowInsets.systemBars).padding(start = 12.dp, top = 56.dp))
    if (nextIn > 0) Box(Modifier.fillMaxSize(), Alignment.Center) { Label("Next episode in $nextIn", Ph.heading, Color.White, FontWeight.SemiBold) }
    if (gotoOpen) PhoneGoToDialog(onGo = { playback.goTo(it); gotoOpen = false; panel = null }, onClose = { gotoOpen = false })
    val close = { panel = null }
    when (panel) {
        Panel.SEARCH_LIVE -> PhonePlayerSearch(c, app.streamsetu.core.data.repo.SearchTab.LIVE, onPlay = { p -> c.play(p, c.queue); panel = null }, onSeries = { sr -> panel = null; onOpenSeries(sr) }, onClose = { panel = null })
        Panel.SEARCH -> PhonePlayerSearch(c, onPlay = { p -> c.play(p, if (p is ChannelPlayable) c.queue else listOf(p)); panel = null }, onSeries = { sr -> panel = null; onOpenSeries(sr) }, onClose = { panel = null })
        Panel.TUNE -> Sheet("Picture tuning", PlayerMenus.picture(playback, tuning).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.SOUND -> Sheet("Sound", PlayerMenus.sound(playback, tuning).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.SUBLOOK -> Sheet("Subtitle look", PlayerMenus.subtitleStyle(playback, styleNow ?: playback.currentSubtitleStyle()).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.QUALITY -> Sheet("Quality", PlayerMenus.quality(playback, qualities).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.QUEUE -> Sheet("Up next", lined.map { t -> SheetItem(t.title, Icons.Filled.Close, false, "Tap to take it out of the queue") { c.watchQueue.remove(t.id) } } + SheetItem("Clear the queue", Icons.Filled.Delete) { c.watchQueue.clear(); panel = null }, close)
        Panel.CHAPTERS -> Sheet("Chapters", PlayerMenus.chapters(playback, chapters).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.JUMPTO -> Sheet("Go to", listOf(SheetItem("Type a time…", Icons.Filled.Edit) { gotoOpen = true }) + PlayerMenus.jumpToPoints(playback).map { e -> SheetItem(e.title, null, e.selected, e.detail, true, e.keepOpen) { e.action() } }, close)
        Panel.SUBFIND -> {
            LaunchedEffect(Unit) {
                subHits = null; subMessage = null
                if (!onlineSubs.configured) { subMessage = "Add your free OpenSubtitles key, account name and password in Settings, Subtitles."; return@LaunchedEffect }
                val title = (item as? EpisodePlayable)?.series?.title ?: item?.title.orEmpty()
                runCatching { onlineSubs.search(title, (item as? app.streamsetu.core.model.MoviePlayable)?.movie?.year, c.settings.subtitleLanguage.value) }
                    .onSuccess { subHits = it; if (it.isEmpty()) subMessage = "No subtitles found for this title." }.onFailure { subMessage = it.message ?: "The search did not work." }
            }
            Sheet("Subtitles online", (subHits ?: emptyList()).map { h -> SheetItem(h.label, Icons.Filled.Subtitles) {
                subScope.launch { runCatching { onlineSubs.download(h) }.onSuccess { playback.addSubtitle(it, "Online") }.onFailure { android.widget.Toast.makeText(context, it.message ?: "That did not work.", android.widget.Toast.LENGTH_LONG).show() } }
            } }.ifEmpty { listOf(SheetItem(subMessage ?: "Searching…", null, false) {}) }, close)
        }
        Panel.AUDIO -> Sheet("Audio", if (audio.isEmpty()) listOf(SheetItem("Only one audio track", null, true) {}) else audio.map { t -> SheetItem(t.label, null, t.selected) { playback.selectAudio(t.id) } }, close)
        Panel.SUBS -> Sheet("Subtitles", listOf(SheetItem("Off", null, subs.none { it.selected }) { playback.selectSubtitle(null) }) + subs.map { t -> SheetItem(t.label, null, t.selected) { playback.selectSubtitle(t.id) } } +
            listOf(SheetItem("Add subtitles from a file…", Icons.Filled.NoteAdd) { pickSubtitle.launch(arrayOf("*/*")) }, SheetItem("Subtitle and sound timing…", Icons.Filled.Sync) { panel = Panel.SYNC }.copy(stays = true)), close)
        Panel.CAST -> {
            var devices by remember { mutableStateOf(c.cast.devices()) }
            DisposableEffect(Unit) { c.cast.startScanning(); onDispose { c.cast.stopScanning() } }
            LaunchedEffect(Unit) { while (true) { devices = c.cast.devices(); delay(1000) } }
            Sheet("Cast to a device", if (devices.isEmpty()) listOf(SheetItem("Looking for devices…", null, false, "Your phone and the Chromecast must be on the same Wi-Fi") {}) else devices.map { route ->
                SheetItem(route.name, Icons.Filled.Cast) {
                    val it2 = item ?: return@SheetItem
                    castScope.launch {
                        val url = c.resolver.resolve(it2.sourceId, it2.streamRef)
                        if (url == null) { android.widget.Toast.makeText(context, "That stream has no address to cast", android.widget.Toast.LENGTH_SHORT).show(); return@launch }
                        if (c.resolver.headers(it2.sourceId).isNotEmpty()) { android.widget.Toast.makeText(context, "This connection needs special headers, which a Chromecast cannot send", android.widget.Toast.LENGTH_LONG).show(); return@launch }
                        val at = playback.positionMs
                        if (state == PlaybackState.Playing) playback.togglePause()
                        c.cast.castTo(route, it2, url, at)
                    }
                }
            }, close, subtitle = "Plain web streams (HLS, MP4) cast best")
        }
        Panel.SLEEP -> Sheet("Sleep timer", listOf(15, 30, 45, 60, 90, 120).map { m -> SheetItem("$m minutes", null, false) { playback.startSleepTimer(m); android.widget.Toast.makeText(context, "Playback will stop in $m minutes", android.widget.Toast.LENGTH_SHORT).show() } } +
            (if (sleepAt > 0) listOf(SheetItem("Turn off", Icons.Filled.Close) { playback.startSleepTimer(0) }) else emptyList()), close,
            subtitle = if (sleepAt > 0) "Stops in ${((sleepAt - System.currentTimeMillis()) / 60_000 + 1).coerceAtLeast(1)} min" else null)
        Panel.SYNC -> Sheet("Timing", if (!playback.canDelay) listOf(SheetItem("Switch to the MPV player", Icons.Filled.Tune, false, "Only MPV can move subtitles and sound") { if (EngineKind.MPV in playback.available) playback.switchEngine(EngineKind.MPV) }) else listOf(
            SheetItem("Subtitles earlier (−0.5 s)", null, false, "Now ${"%+.1f".format(subDelay / 1000.0)} s", stays = true) { playback.setSubtitleDelay(subDelay - 500) },
            SheetItem("Subtitles later (+0.5 s)", null, false, "Now ${"%+.1f".format(subDelay / 1000.0)} s", stays = true) { playback.setSubtitleDelay(subDelay + 500) },
            SheetItem("Sound earlier (−0.1 s)", null, false, "Now ${"%+.1f".format(audioDelay / 1000.0)} s", stays = true) { playback.setAudioDelay(audioDelay - 100) },
            SheetItem("Sound later (+0.1 s)", null, false, "Now ${"%+.1f".format(audioDelay / 1000.0)} s", stays = true) { playback.setAudioDelay(audioDelay + 100) },
            SheetItem("Reset both", Icons.Filled.Replay) { playback.setSubtitleDelay(0); playback.setAudioDelay(0) }), close)
        Panel.SPEED -> Sheet("Speed", listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f).map { v -> SheetItem(if (v == 1f) "Normal" else "${v}×", null, v == speed) { playback.setSpeed(v) } }, close)
        Panel.PICTURE -> Sheet("Picture", AspectMode.entries.map { m -> SheetItem(m.label, null, m == aspect) { playback.setAspect(m) } }, close)
        Panel.ENGINE -> Sheet("Player", playback.available.toList().map { k -> SheetItem(k.label, null, k == playback.engineKind, if (k == EngineKind.MPV) "MKV, AVI and unusual formats" else "HLS, MP4 and transport streams") { playback.switchEngine(k) } }, close, subtitle = "Switching retries this same stream.")
        Panel.CHANNELS -> Sheet("Channels", listOf(SheetItem("Search channels…", Icons.Filled.Search) { panel = Panel.SEARCH_LIVE }) + c.queue.filterIsInstance<ChannelPlayable>().map { ch -> SheetItem("${ch.channel.number?.let { "$it  " } ?: ""}${ch.channel.name}", null, ch.id == item?.id) { c.play(ch, c.queue) } }, close)
        Panel.EPISODES -> {
            val eps = c.queue.filterIsInstance<EpisodePlayable>().filter { (item as? EpisodePlayable)?.episode?.season == it.episode.season }
            Sheet("Episodes", eps.map { ep -> SheetItem("${ep.episode.number}.  ${ep.episode.title}", null, ep.id == item?.id) { c.play(ep, c.queue) } }, close, subtitle = "Season ${(item as? EpisodePlayable)?.episode?.season ?: ""}")
        }
        Panel.MORE -> Sheet("More", buildList {
            if (!live && resumedFrom > 0) add(SheetItem("Start over", Icons.Filled.Replay) { playback.startOver() })
            add(SheetItem("Picture tuning", Icons.Filled.Tune, false, "Brightness, contrast, saturation, decoding", true, true) { panel = Panel.TUNE })
            add(SheetItem("Sound", Icons.Filled.VolumeUp, false, "Volume boost, even out loudness", true, true) { panel = Panel.SOUND })
            add(SheetItem("Subtitle look", Icons.Filled.FormatSize, false, "Size, colour, position, background", true, true) { panel = Panel.SUBLOOK })
            add(SheetItem("Find subtitles online", Icons.Filled.Subtitles, false, "From OpenSubtitles, with your free key", true, true) { panel = Panel.SUBFIND })
            if (qualities.isNotEmpty()) add(SheetItem("Quality", Icons.Filled.HighQuality, false, "Choose the resolution", true, true) { panel = Panel.QUALITY })
            if (!live && lined.isNotEmpty()) add(SheetItem("Up next: ${lined.size} in the queue", Icons.Filled.List, false, null, true, true) { panel = Panel.QUEUE })
            if (!live && chapters.isNotEmpty()) add(SheetItem("Chapters", Icons.Filled.List, false, null, true, true) { panel = Panel.CHAPTERS })
            if (!live) add(SheetItem("Go to time…", Icons.Filled.Schedule, false, "Type an exact time, or jump by tenths", true, true) { panel = Panel.JUMPTO })
            if (live) (item as? ChannelPlayable)?.let { cp -> epgNext?.let { nx -> add(SheetItem("Remind me: " + nx.title, Icons.Filled.Notifications, false, "A notification when it starts") { subScope.launch { app.streamsetu.tv.Reminders.schedule(c, context, cp.channel, nx) } }) } }
            add(SheetItem("Remember settings for this title: " + if (playback.rememberPerTitle) "on" else "off", Icons.Filled.Bookmark, false, "Audio, subtitles, speed, picture, sound", true, true) { playback.rememberPerTitle = !playback.rememberPerTitle })
            if (item is EpisodePlayable) add(SheetItem("Play next episode by itself: " + if (c.settings.playNextAutomatically.value) "on" else "off", Icons.Filled.SkipNext, false, null, true, true) { c.settings.setPlayNext(!c.settings.playNextAutomatically.value) })
            add(SheetItem("Skip length: ${c.settings.seekSeconds.value} seconds", Icons.Filled.FastForward, false, "Tap to change: 5, 10, 15, 30, 85", true, true) { c.settings.setSeekSeconds(listOf(5, 10, 15, 30, 85).let { l -> l[(l.indexOf(c.settings.seekSeconds.value) + 1).mod(l.size)] }) })
            add(SheetItem("Stream information: " + if (c.settings.showStreamInfo.value) "on" else "off", Icons.Filled.Info) { c.settings.setShowStreamInfo(!c.settings.showStreamInfo.value) })
            add(SheetItem(if (sleepAt > 0) "Sleep timer: ${((sleepAt - System.currentTimeMillis()) / 60_000 + 1).coerceAtLeast(1)} min left" else "Sleep timer", Icons.Filled.Bedtime) { panel = Panel.SLEEP }.copy(stays = true))
            add(SheetItem("Save a picture of this frame", Icons.Filled.PhotoCamera) {
                playback.snapshot { bmp ->
                    val where = bmp?.let { app.streamsetu.tv.Screenshots.save(context, it, item?.title.orEmpty()) }
                    android.widget.Toast.makeText(context, if (where != null) "Saved in $where" else "A picture could not be taken from this stream", android.widget.Toast.LENGTH_SHORT).show()
                }
            })
            if (c.cast.available() && item != null) add(if (casting != null) SheetItem("Stop casting", Icons.Filled.CastConnected) { val at = c.cast.positionMs(); c.cast.stop(); if (!live && at > 0) playback.seekBy(at - playback.positionMs) } else SheetItem("Cast to a device…", Icons.Filled.Cast) { panel = Panel.CAST }.copy(stays = true))
            if (live) add(SheetItem("Multi-View", Icons.Filled.GridView, false, "Several channels at once") { onMultiView() })
            if (live && c.previousLive != null) add(SheetItem("Last channel", Icons.Filled.History) { c.lastChannel() })
            if (android.os.Build.VERSION.SDK_INT >= 26) add(SheetItem("Picture in picture", Icons.Filled.PictureInPictureAlt) { (context as? Activity)?.enterPictureInPictureMode(android.app.PictureInPictureParams.Builder().build()) })
            add(SheetItem("Close player", Icons.Filled.Close) { onClose() })
        }, close)
        null -> {}
    }
}

@Composable
private fun BigButton(icon: androidx.compose.ui.graphics.vector.ImageVector, size: Int, onClick: () -> Unit) {
    val label = when (icon) {
        Icons.Filled.PlayArrow -> "Play"; Icons.Filled.Pause -> "Pause"; Icons.Filled.SkipNext -> "Next"; Icons.Filled.SkipPrevious -> "Previous"
        Icons.Filled.Replay10 -> "Skip back"; Icons.Filled.Forward10 -> "Skip forward"; else -> "Button"
    }
    Box(Modifier.size(size.dp).clip(CircleShape).background(Color(0x55000000)).semantics { contentDescription = label; role = Role.Button }.clickable(onClick = onClick), Alignment.Center) { Icon(icon, Color.White, (size * 0.6f).dp) }
}

/** A seek bar you can tap or drag. The thumb grows while it is held. */
@Composable
private fun SeekBar(frac: Float, modifier: Modifier, onStart: () -> Unit, onChange: (Float) -> Unit, onEnd: (Float) -> Unit) {
    var width by remember { mutableIntStateOf(1) }
    var held by remember { mutableStateOf(false) }
    var last by remember { mutableFloatStateOf(frac) }
    Box(
        modifier.height(40.dp)
            .semantics {
                contentDescription = "Seek bar"; stateDescription = "${(frac * 100).toInt()} percent"
                progressBarRangeInfo = ProgressBarRangeInfo(frac.coerceIn(0f, 1f), 0f..1f)
                setProgress { v -> onStart(); onEnd(v.coerceIn(0f, 1f)); true }
            }
            .pointerInput(Unit) { detectTapGestures { o -> val f = (o.x / width).coerceIn(0f, 1f); onStart(); onEnd(f) } }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { o -> held = true; last = (o.x / width).coerceIn(0f, 1f); onStart(); onChange(last) },
                    onDragEnd = { held = false; onEnd(last) },
                    onDragCancel = { held = false; onEnd(last) },
                    onHorizontalDrag = { change, _ -> change.consume(); last = (change.position.x / width).coerceIn(0f, 1f); onChange(last) },
                )
            }
            .onSizeChanged { width = it.width.coerceAtLeast(1) },
        Alignment.CenterStart,
    ) {
        Box(Modifier.fillMaxWidth().height(4.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp)))
        Box(Modifier.fillMaxWidth(frac.coerceIn(0f, 1f)).height(4.dp).background(Tokens.accent, RoundedCornerShape(2.dp)))
        Box(Modifier.fillMaxWidth().height(40.dp)) {
            Box(Modifier.align(Alignment.CenterStart).graphicsLayer { translationX = (width * frac.coerceIn(0f, 1f)) - (if (held) 9.dp.toPx() else 6.dp.toPx()) }.size(if (held) 18.dp else 12.dp).background(Color.White, CircleShape))
        }
    }
}

