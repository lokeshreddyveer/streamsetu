package app.streamsetu.tv.ui.screens.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** The 13 categories, most used first; the technical ones are at the bottom. */
enum class Category(val title: String, val subtitle: String, val icon: ImageVector) {
    PLAYBACK("Playback", "Engine, buffering, resume and recovery", Icons.Filled.PlayArrow),
    VIDEO("Video & Display", "Picture size, decoding and screen", Icons.Filled.Tv),
    AUDIO("Audio", "Language, surround and track memory", Icons.Filled.VolumeUp),
    SUBTITLES("Subtitles & Accessibility", "Subtitle style, motion and contrast", Icons.Filled.Subtitles),
    LIVE("Live TV", "Channel keys, numbers and guide time", Icons.Filled.LiveTv),
    LIBRARIES("Libraries & Folders", "Connections, combined libraries, folders", Icons.Filled.Layers),
    SEARCH("Search & Catalog", "Sorting, search history and the index", Icons.Filled.Search),
    FAVOURITES("Favorites & History", "Lists, history and Home rows", Icons.Filled.Favorite),
    APPEARANCE("Appearance & Sounds", "Posters, banner, animation, interface sounds", Icons.Filled.Palette),
    PRIVACY("Privacy & Security", "Folder PIN, relock, clearing data", Icons.Filled.Lock),
    STORAGE("Storage & Backup", "Cache, backup and reset", Icons.Filled.Storage),
    DIAGNOSTICS("Diagnostics", "Playback facts and a safe report", Icons.Filled.Troubleshoot),
    ABOUT("About StreamSetu", "Version, licenses and support", Icons.Filled.Info),
}

/**
 * Settings: Settings Home (this list) → a category → its controls. The list takes about a third of the width and the controls the rest.
 * OK or Right on a category moves into its controls; Back returns to the list on the same category. Everything saves the moment it changes.
 */
@Composable
fun SettingsScreen(c: AppContainer, nav: Navigator) {
    var selected by rememberSaveable { mutableStateOf(Category.PLAYBACK.name) }
    val current = Category.valueOf(selected)
    val listEntry = LocalContentEntry.current ?: remember { FocusRequester() }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    var inPanel by remember { mutableStateOf(false) }
    val rows = remember { Category.entries.associateWith { FocusRequester() } }

    BackHandler(enabled = inPanel) { runCatching { rows[current]?.requestFocus() } }

    Row(Modifier.fillMaxSize()) {
        Column(Modifier.weight(0.32f).fillMaxHeight().background(Tokens.panel).padding(horizontal = 8.dp, vertical = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Label("Settings", Tokens.pageTitle, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = 8.dp))
            Label("StreamSetu · Fire TV", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 8.dp, bottom = 6.dp))
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Category.entries.forEach { cat ->
                    val isSel = cat == current
                    var dwell by remember { mutableStateOf(false) }
                    LaunchedEffect(dwell) { if (dwell) { delay(220); selected = cat.name } }
                    Focusable({ selected = cat.name; focusManager.moveFocus(androidx.compose.ui.focus.FocusDirection.Right) },
                        (if (isSel) Modifier.focusRequester(listEntry) else Modifier).then(Modifier.focusRequester(rows.getValue(cat))).fillMaxWidth()
                            .onPreviewKeyEvent { e -> if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) { selected = cat.name; focusManager.moveFocus(androidx.compose.ui.focus.FocusDirection.Right) } else false },
                        shape = RoundedCornerShape(8.dp), container = if (isSel) Tokens.elevated else Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1.0f, onFocus = { dwell = it }) { f ->
                        Row(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                            androidx.compose.foundation.Image(cat.icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(if (isSel || f) Tokens.accent else Tokens.textTertiary))
                            Label(cat.title, Tokens.row, if (isSel) Tokens.text else Tokens.textSecondary, if (isSel) FontWeight.SemiBold else FontWeight.Normal)
                        }
                    }
                }
            }
        }
        Column(Modifier.weight(0.68f).fillMaxHeight().onFocusChanged { inPanel = it.hasFocus }.verticalScroll(rememberScrollState()).padding(start = 22.dp, end = Tokens.safeHorizontal, top = Tokens.safeVertical, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column {
                Label(current.title, Tokens.pageTitle, Tokens.text, FontWeight.Bold)
                Label(current.subtitle, Tokens.small, Tokens.textSecondary)
            }
            SettingsPanel(current, c, nav)
        }
    }
}


/** The controls of one category. Shared by the remote layout (beside the list) and the phone layout (a page of its own). */
@Composable
fun SettingsPanel(current: Category, c: AppContainer, nav: Navigator) {
    when (current) {
        Category.PLAYBACK -> PlaybackSettings(c)
        Category.VIDEO -> VideoSettings(c)
        Category.AUDIO -> AudioSettings(c)
        Category.SUBTITLES -> SubtitleSettings(c)
        Category.LIVE -> LiveSettings(c)
        Category.LIBRARIES -> LibrarySettings(c, nav)
        Category.SEARCH -> SearchSettings(c)
        Category.FAVOURITES -> FavouriteSettings(c)
        Category.APPEARANCE -> AppearanceSettings(c)
        Category.PRIVACY -> PrivacySettings(c)
        Category.STORAGE -> StorageSettings(c)
        Category.DIAGNOSTICS -> DiagnosticsSettings(c)
        Category.ABOUT -> AboutSettings(c)
    }
}

// ---------------------------------------------------------------------------------------------------------------------------------------------

private val languages = listOf("" to "Any", "en" to "English", "hi" to "Hindi", "te" to "Telugu", "ta" to "Tamil", "kn" to "Kannada", "ml" to "Malayalam", "ur" to "Urdu", "ar" to "Arabic", "es" to "Spanish", "fr" to "French", "de" to "German", "pt" to "Portuguese")

@Composable
private fun connections(c: AppContainer): List<Source> = c.sources.sources.collectAsState(initial = emptyList()).value.filter { !it.draft }

@Composable
private fun AdvancedToggle(content: @Composable ColumnScope.() -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingGroup("Advanced") {
        SettingRow(if (open) "Hide advanced settings" else "Show advanced settings", "Technical options. The defaults suit almost everyone.", if (open) "Shown" else "Hidden") { open = !open }
        if (open) content()
    }
}

@Composable
fun PlaybackSettings(c: AppContainer) {
    val s = c.settings
    val engine by s.enginePreference.collectAsState()
    val liveBuf by s.liveBuffering.collectAsState(); val vodBuf by s.vodBuffering.collectAsState()
    val resume by s.resumeAutomatically.collectAsState(); val seek by s.seekSeconds.collectAsState(); val next by s.playNextAutomatically.collectAsState(); val remember by s.rememberPosition.collectAsState()
    val retry by s.automaticRetry.collectAsState(); val patience by s.stallPatience.collectAsState()
    val mpv = EngineKind.MPV in c.playback.available
    val conns = connections(c)
    var tick by remember { mutableIntStateOf(0) }; tick.let { }

    SettingGroup("Player engine", "Automatic uses ExoPlayer (Media3) for HLS, MP4, DASH and MPEG-TS, and MPV for MKV, AVI and RTSP. If a format is not supported, the other engine is tried once; the same stream is retried, never a different one.") {
        ChoiceRow("Default engine", options = listOf(EnginePreference.AUTOMATIC to "Automatic", EnginePreference.EXOPLAYER to "Media3 ExoPlayer", EnginePreference.MPV to if (mpv) "MPV" else "MPV (not available)"), value = engine) { if (it != EnginePreference.MPV || mpv) s.setEngine(it) }
        if (!mpv) InfoRow("MPV", "Not available", "MPV needs Android 8 or later.")
        if (conns.size > 1 || (conns.isNotEmpty() && s.engineFor(conns.first().id) != null)) conns.forEach { src ->
            val over = s.engineFor(src.id)
            ChoiceRow("Engine for ${src.name}", "Overrides the default for this connection only.", listOf<Pair<EnginePreference?, String>>(null to "Use global default", EnginePreference.AUTOMATIC to "Automatic", EnginePreference.EXOPLAYER to "Media3 ExoPlayer") + (if (mpv) listOf(EnginePreference.MPV to "MPV") else emptyList()), over) { s.setEngineFor(src.id, it); tick++ }
        }
    }
    SettingGroup("Buffering", "A bigger buffer rides out a slow provider but delays a channel change a little. Takes effect on the next stream.") {
        ChoiceRow("Live TV buffer", options = listOf(BufferingMode.LOW_LATENCY to "Low latency", BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), value = liveBuf) { s.setLiveBuffering(it) }
        ChoiceRow("Movies and series buffer", options = listOf(BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), value = vodBuf) { s.setVodBuffering(it) }
        conns.forEach { src ->
            if (conns.size > 1) ChoiceRow("Live buffer for ${src.name}", "Overrides the global Live TV buffer for this connection.", listOf<Pair<BufferingMode?, String>>(null to "Use global default", BufferingMode.LOW_LATENCY to "Low latency", BufferingMode.AUTOMATIC to "Balanced", BufferingMode.LARGE to "Stable"), s.liveBufferFor(src.id)) { s.setLiveBufferFor(src.id, it); tick++ }
        }
    }
    SettingGroup("Movies and series") {
        ToggleRow("Remember playback position", "Saves where you stop so Continue Watching works.", remember) { s.setRememberPosition(it) }
        ToggleRow("Resume automatically", "Continue a partly watched title where it stopped.", resume && remember, enabled = remember, reason = "Turn on Remember playback position first.") { s.setResumeAutomatically(it) }
        ChoiceRow("Skip interval", "How far Left and Right jump while watching.", listOf(5 to "5 seconds", 10 to "10 seconds", 15 to "15 seconds", 30 to "30 seconds"), seek) { s.setSeekSeconds(it) }
        val confirmLeave by s.confirmLeavingPlayer.collectAsState()
        ToggleRow("Ask before leaving the player", "Back shows Continue watching or Exit instead of leaving at once.", confirmLeave) { s.setConfirmLeavingPlayer(it) }
        ToggleRow("Play the next episode automatically", "Only continues to the very next episode; it never plays across a missing one.", next) { s.setPlayNext(it) }
    }
    SettingGroup("Recovery", "Switching to a different provider stream is always a choice you make (Choose Stream). It never happens by itself.") {
        ToggleRow("Retry a failing stream automatically", "Off: the stream stops at once and waits for you to press Try Again.", retry) { s.setAutomaticRetry(it) }
        ChoiceRow("How long to wait for a stream to load", "Past this, loading counts as a failure.", listOf("SHORT" to "Short (10 s live)", "NORMAL" to "Normal (18 s live)", "LONG" to "Long (30 s live)"), patience) { s.setStallPatience(it) }
    }
    val dec by s.decoderFallback.collectAsState()
    AdvancedToggle {
        ToggleRow("Decoder fallback", "If a hardware decoder fails on a stream, another decoder is tried instead of failing. Applies to the next stream.", dec) { s.setDecoderFallback(it) }
        ActionRow("Reset player settings", "Puts every setting on the Playback, Audio and Subtitles pages back to its default.", "Reset", danger = true) { s.resetPlayerPreferences() }
    }
}

@Composable
fun VideoSettings(c: AppContainer) {
    val s = c.settings
    val aspect by s.defaultAspect.collectAsState(); val info by s.showStreamInfo.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val display = remember { runCatching { (context.getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager).getDisplay(0) }.getOrNull() }
    val mode = display?.mode
    val hdr = remember { runCatching { display?.hdrCapabilities?.supportedHdrTypes?.map { when (it) { 1 -> "Dolby Vision"; 2 -> "HDR10"; 3 -> "HLG"; 4 -> "HDR10+"; else -> "HDR" } } }.getOrNull().orEmpty() }
    SettingGroup("Picture") {
        ChoiceRow("Default picture size", "Fit keeps the whole picture. Fill and Zoom crop the edges to remove black bars. You can still change it while watching.", listOf("FIT" to "Fit", "FILL" to "Fill", "ZOOM" to "Zoom"), aspect) { s.setDefaultAspect(it) }
        ToggleRow("Show stream information while playing", "A small overlay with the engine, resolution and codecs.", info) { s.setShowStreamInfo(it) }
        SettingRow("Quality", "Streams from IPTV providers have one quality each; adaptive streams (HLS with several levels) are chosen automatically.", "Automatic")
    }
    SettingGroup("This screen") {
        InfoRow("Resolution", mode?.let { "${it.physicalWidth}×${it.physicalHeight} at ${"%.0f".format(it.refreshRate)} Hz" } ?: "unknown")
        InfoRow("HDR formats the TV accepts", hdr.joinToString(", ").ifBlank { "none reported" }, "Played only when the TV, the decoder and the stream all support it.")
        SettingRow("Match the display's refresh rate to the video", "Switches the TV's refresh rate to the video's frame rate.", "Not available", enabled = false, reason = "Needs Android 11 or later and a display that allows mode switching. Not offered in this version.")
    }
    SettingGroup("Decoders on this device", "Hardware decoding is used whenever the device has it.") {
        InfoRow("Hardware video decoders", c.maintenance.hardwareDecoders().joinToString(", ").ifBlank { "none found" })
    }
}

@Composable
fun AudioSettings(c: AppContainer) {
    val s = c.settings
    val lang by s.audioLanguage.collectAsState(); val remember by s.rememberAudioChoice.collectAsState(); val pass by s.surroundPassthrough.collectAsState()
    SettingGroup("Language") {
        ChoiceRow("Preferred audio language", "Chosen automatically when a stream has several audio tracks. You can still switch while watching.", languages, lang) { s.setAudioLanguage(it) }
        ToggleRow("Remember the track I choose", "The language you pick while watching becomes the preferred language.", remember) { s.setRememberAudioChoice(it) }
    }
    SettingGroup("Sound output", "Takes effect on the next stream.") {
        ToggleRow("Surround sound passthrough", "On: surround is sent to the TV or receiver as it is, when they support it. Off: this device decodes to stereo (a stereo downmix).", pass) { s.setSurroundPassthrough(it) }
        SettingRow("Audio sync offset", "Shifts the sound earlier or later against the picture.", "Not available", enabled = false, reason = "The Media3 player used for most streams has no sound-delay control.")
    }
}

@Composable
fun SubtitleSettings(c: AppContainer) {
    val s = c.settings; val ui = c.ui
    val mode by s.subtitleMode.collectAsState(); val lang by s.subtitleLanguage.collectAsState(); val size by s.subtitleSize.collectAsState(); val bg by s.subtitleBackground.collectAsState(); val outline by s.subtitleOutline.collectAsState()
    val anim by ui.animation.collectAsState(); val contrast by ui.highContrastFocus.collectAsState()
    SettingGroup("Subtitles", "Style applies to the next stream.") {
        ChoiceRow("Subtitles", "Auto turns them on when the sound is not in your preferred audio language.", listOf("OFF" to "Off", "AUTO" to "Auto", "ON" to "On when available"), mode) { s.setSubtitleMode(it) }
        ChoiceRow("Subtitle language", options = languages, value = lang) { s.setSubtitleLanguage(it) }
        ChoiceRow("Size", options = listOf("SMALL" to "Small", "MEDIUM" to "Medium", "LARGE" to "Large", "XLARGE" to "Extra large"), value = size) { s.setSubtitleSize(it) }
        ChoiceRow("Background", options = listOf("NONE" to "None", "DARK" to "Dark box"), value = bg) { s.setSubtitleBackground(it) }
        ToggleRow("Outline", "A dark edge around the letters.", outline) { s.setSubtitleOutline(it) }
        SettingRow("Subtitle delay", "Shifts subtitles earlier or later.", "Not available", enabled = false, reason = "Only the MPV engine can do this, and it is not exposed yet.")
    }
    SettingGroup("Accessibility") {
        ChoiceRow("Animation", "Reduced and Off remove sliding and fading. Android's own \"remove animations\" setting is also respected.", listOf(app.streamsetu.core.settings.AnimationLevel.FULL to "Full", app.streamsetu.core.settings.AnimationLevel.REDUCED to "Reduced", app.streamsetu.core.settings.AnimationLevel.OFF to "Off"), anim) { ui.setAnimation(it) }
        ToggleRow("High-contrast focus", "A thicker white frame around whatever the remote is on.", contrast) { ui.setHighContrastFocus(it) }
        val scale by s.textScalePercent.collectAsState()
        ChoiceRow("Text size", "Scales every label in the app.", listOf(100 to "Standard", 115 to "Large", 130 to "Extra large"), scale) { s.setTextScalePercent(it) }
    }
}

@Composable
fun LiveSettings(c: AppContainer) {
    val s = c.settings; val ui = c.ui
    val inv by s.invertChannelKeys.collectAsState(); val nums by s.showChannelNumbers.collectAsState(); val resumeLast by s.resumeLastChannel.collectAsState(); val off by ui.epgOffsetMinutes.collectAsState()
    SettingGroup("Watching live TV") {
        ToggleRow("Swap the channel keys", "Off: Up is the next channel and Down the previous one. On: the other way round.", inv) { s.setInvertChannelKeys(it) }
        ToggleRow("Show channel numbers", "The number the provider gives each channel, in lists and when typing a number.", nums) { s.setShowChannelNumbers(it) }
        val group by ui.groupDuplicates.collectAsState()
        ToggleRow("Fold the same channel into one row", "A channel that comes in HD, FHD and SD, or from two connections, is one row. Hold OK on it to pick a version.", group) { ui.setGroupDuplicates(it) }
        ToggleRow("Open Live TV on the last channel", "Starts the last channel you watched when Live TV opens. Off: nothing plays until you choose a channel.", resumeLast) { s.setResumeLastChannel(it) }
    }
    SettingGroup("Guide") {
        ChoiceRow("Guide time shift", "For a provider whose guide is early or late: every programme time moves by this much.", listOf(-120, -90, -60, -30, 0, 30, 60, 90, 120).map { it to if (it == 0) "None" else (if (it > 0) "+" else "−") + "${kotlin.math.abs(it)} min" }, off) { ui.setEpgOffsetMinutes(it) }
        val zone by s.catchupZone.collectAsState()
        ChoiceRow("Catch-up start time", "Providers read the start of a catch-up programme in their own time zone. If a catch-up plays the wrong programme, switch this.", listOf("UTC" to "UTC", "DEVICE" to "This device's time zone"), zone) { s.setCatchupZone(it) }
        InfoRow("Time zone", java.util.TimeZone.getDefault().id, "Guide times are shown in this device's time zone.")
    }
}

internal fun fmtBytes(b: Long): String = when { b >= 1L shl 30 -> "%.1f GB".format(b / (1L shl 30).toDouble()); b >= 1L shl 20 -> "%.1f MB".format(b / (1L shl 20).toDouble()); b >= 1L shl 10 -> "%.0f KB".format(b / 1024.0); else -> "$b B" }
