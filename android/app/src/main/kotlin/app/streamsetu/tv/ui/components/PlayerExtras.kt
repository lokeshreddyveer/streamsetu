package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.playback.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** One line of a player panel. The Fire TV panels and the phone sheets both draw these, so the options are the same everywhere. */
class PlayerEntry(val title: String, val detail: String? = null, val selected: Boolean = false, val keepOpen: Boolean = false, val action: () -> Unit)

/** The extra player options (picture, sound, subtitle look, quality, chapters, go to time), built from the controller's state. */
object PlayerMenus {
    private fun step(name: String, value: Int, unit: String = "", min: Int, max: Int, by: Int, set: (Int) -> Unit) = listOf(
        PlayerEntry("$name  ${if (value > 0 && min < 0) "+" else ""}$value$unit", "Press the next two lines to change it", keepOpen = true) {},
        PlayerEntry("$name up", keepOpen = true) { set((value + by).coerceAtMost(max)) },
        PlayerEntry("$name down", keepOpen = true) { set((value - by).coerceAtLeast(min)) },
    )

    fun picture(pb: PlaybackController, t: PlayerTuning): List<PlayerEntry> = buildList {
        val mpv = pb.engine.value?.supportsPictureTuning == true
        if (!mpv) add(PlayerEntry("Switch to the MPV player for picture controls", "ExoPlayer cannot change brightness, contrast, saturation or gamma") { pb.switchEngine(EngineKind.MPV) })
        else {
            addAll(step("Brightness", t.brightness, "", -100, 100, 5) { pb.setTuning(t.copy(brightness = it)) })
            addAll(step("Contrast", t.contrast, "", -100, 100, 5) { pb.setTuning(t.copy(contrast = it)) })
            addAll(step("Saturation", t.saturation, "", -100, 100, 5) { pb.setTuning(t.copy(saturation = it)) })
            addAll(step("Gamma", t.gamma, "", -100, 100, 5) { pb.setTuning(t.copy(gamma = it)) })
            add(PlayerEntry("Deinterlace: " + if (t.deinterlace) "on" else "off", "For old interlaced channels that show combing on movement", keepOpen = true) { pb.setTuning(t.copy(deinterlace = !t.deinterlace)) })
        }
        add(PlayerEntry("Decoding: " + if (t.softwareDecoding) "software" else "hardware", "Software helps with a picture that is green, blocky or frozen; it uses more power", keepOpen = true) { pb.setTuning(t.copy(softwareDecoding = !t.softwareDecoding)) })
        if (t.picture) add(PlayerEntry("Reset picture", keepOpen = true) { pb.setTuning(t.copy(brightness = 0, contrast = 0, saturation = 0, gamma = 0, deinterlace = false)) })
    }

    fun sound(pb: PlaybackController, t: PlayerTuning): List<PlayerEntry> = buildList {
        for (p in listOf(100, 115, 130, 150)) add(PlayerEntry(if (p == 100) "Normal volume" else "Boost to $p%", if (p == 150) "Loud: can distort on some streams" else null, selected = t.boostPercent == p) { pb.setTuning(t.copy(boostPercent = p)) })
        if (pb.engine.value?.kind == EngineKind.MPV) add(PlayerEntry("Even out loudness: " + if (t.normalizeLoudness) "on" else "off", "Quieter explosions, louder speech", keepOpen = true) { pb.setTuning(t.copy(normalizeLoudness = !t.normalizeLoudness)) })
    }

    private val colours = listOf("White" to 0xFFFFFFFF.toInt(), "Yellow" to 0xFFFFEB3B.toInt(), "Cyan" to 0xFF4DD0E1.toInt(), "Green" to 0xFF7CE38B.toInt())

    fun subtitleStyle(pb: PlaybackController, s: SubtitleStyle): List<PlayerEntry> = buildList {
        for ((name, v) in listOf("Small" to 0.8f, "Normal" to 1f, "Large" to 1.3f, "Extra large" to 1.6f)) add(PlayerEntry("Size: $name", selected = s.scale == v, keepOpen = true) { pb.setSubtitleStyle(s.copy(scale = v)) })
        for ((name, v) in colours) add(PlayerEntry("Colour: $name", selected = s.color == v, keepOpen = true) { pb.setSubtitleStyle(s.copy(color = v)) })
        for ((name, v) in listOf("Bottom" to 0, "Raised" to 2, "High" to 4)) add(PlayerEntry("Position: $name", selected = s.raise == v, keepOpen = true) { pb.setSubtitleStyle(s.copy(raise = v)) })
        add(PlayerEntry("Dark box behind the text: " + if (s.darkBackground) "on" else "off", keepOpen = true) { pb.setSubtitleStyle(s.copy(darkBackground = !s.darkBackground)) })
        add(PlayerEntry("Outline: " + if (s.outline) "on" else "off", keepOpen = true) { pb.setSubtitleStyle(s.copy(outline = !s.outline)) })
    }

    fun quality(pb: PlaybackController, q: List<TrackOption>): List<PlayerEntry> =
        if (q.isEmpty()) listOf(PlayerEntry("This stream offers one quality", "Nothing to choose", keepOpen = true) {})
        else listOf(PlayerEntry("Automatic", "The player picks for your connection", selected = q.none { it.selected }) { pb.selectQuality(null) }) + q.map { o -> PlayerEntry(o.label, selected = o.selected) { pb.selectQuality(o.id) } }

    fun chapters(pb: PlaybackController, ch: List<Chapter>): List<PlayerEntry> =
        if (ch.isEmpty()) listOf(PlayerEntry("This movie has no chapters", keepOpen = true) {}) else ch.map { c -> PlayerEntry(c.title, clock(c.startMs)) { pb.goTo(c.startMs) } }

    /** Jump to a point in a movie in one press: the start, and each tenth of it. */
    fun jumpToPoints(pb: PlaybackController): List<PlayerEntry> {
        val d = pb.durationMs
        return if (d <= 0) emptyList() else (0..9).map { i -> PlayerEntry(if (i == 0) "Start  ${clock(0)}" else "${i * 10}%  ${clock(d * i / 10)}") { pb.goTo(d * i / 10) } }
    }

    fun clock(ms: Long): String { val s = ms / 1000; return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60) }

    /** "1:23:45", "83:45" or "45" (seconds) as milliseconds, or null when it is not a time. */
    fun parseTime(text: String): Long? {
        val parts = text.trim().split(':').map { it.trim().toLongOrNull() ?: return null }
        if (parts.isEmpty() || parts.size > 3 || parts.any { it < 0 }) return null
        return parts.fold(0L) { acc, p -> acc * 60 + p } * 1000
    }
}

/** A box in the corner with the numbers a person who wants them looks for: the engine, the picture, the sound, the decoder, how much is buffered, and dropped frames. */
@Composable
fun StatsOverlay(c: AppContainer, modifier: Modifier = Modifier) {
    val show by c.settings.showStreamInfo.collectAsState()
    if (!show) return
    var lines by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    LaunchedEffect(Unit) {
        while (true) {
            val pb = c.playback
            lines = listOf("Player" to (pb.engineKind?.label ?: "none"), "State" to pb.state.value.toString().substringBefore('(').lowercase(), "Position" to PlayerMenus.clock(pb.positionMs) + (pb.durationMs.takeIf { it > 0 }?.let { " / " + PlayerMenus.clock(it) } ?: "")) +
                pb.engine.value?.diagnostics().orEmpty().toList()
            delay(1000)
        }
    }
    Column(modifier.background(Color(0xCC000000), RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Label("Stats", Tokens.caption, Tokens.accent, FontWeight.Bold)
        lines.forEach { (k, v) -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { Label(k, Tokens.caption, Tokens.textTertiary, modifier = Modifier.width(110.dp)); Label(v, Tokens.caption, Color.White, maxLines = 1) } }
    }
}

/** Shown over the screens while the player is minimized (the picture is closed and the sound keeps playing): what is playing and which keys to use. */
@Composable
fun TvMiniPlayer(c: AppContainer) {
    val item by c.playback.current.collectAsState()
    val audioOnly by c.playback.audioOnly.collectAsState()
    val state by c.playback.state.collectAsState()
    val shown = item ?: return
    if (!audioOnly) return
    val paused = state == PlaybackState.Paused
    Box(Modifier.fillMaxSize().padding(end = 32.dp, bottom = 24.dp), contentAlignment = androidx.compose.ui.Alignment.BottomEnd) {
        Column(Modifier.widthIn(max = 380.dp).background(Color(0xE6101418), RoundedCornerShape(14.dp)).padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Label((if (paused) "Paused  ·  " else "Playing  ·  ") + (if (shown is app.streamsetu.core.model.EpisodePlayable) shown.series.title else shown.title), Tokens.small, Color.White, FontWeight.SemiBold, maxLines = 1)
            Label("Menu or Info: back to the picture   ·   Play/Pause: " + if (paused) "resume" else "pause", Tokens.caption, Tokens.textSecondary, maxLines = 1)
        }
    }
}
