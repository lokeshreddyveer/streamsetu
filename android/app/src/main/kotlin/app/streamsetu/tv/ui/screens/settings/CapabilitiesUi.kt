package app.streamsetu.tv.ui.screens.settings

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.diagnostics.capability.*
import kotlinx.coroutines.launch
import java.io.File
import java.util.Date

/** A few fixed streams to ask the advisor about. Only a format: no address, no title. */
private val sampleStreams = listOf(
    "H.264 1080p30 in MP4" to StreamFormat("mp4", "video/avc", profile = 8, width = 1920, height = 1080, frameRate = 30f),
    "HEVC Main10 2160p60 in MKV" to StreamFormat("mkv", "video/hevc", profile = 2, width = 3840, height = 2160, frameRate = 60f, bitDepth = 10, hdr = "HDR10"),
    "VP9 Profile 2 2160p60 in WebM" to StreamFormat("webm", "video/x-vnd.on2.vp9", profile = 4, width = 3840, height = 2160, frameRate = 60f, bitDepth = 10),
    "AV1 Main 1080p60 in MP4" to StreamFormat("mp4", "video/av01", profile = 1, width = 1920, height = 1080, frameRate = 60f),
    "H.264 576p25 in AVI" to StreamFormat("avi", "video/avc", profile = 8, width = 1024, height = 576, frameRate = 25f),
    "A format with no details" to StreamFormat(null, null, width = null, height = null),
)
private val sampleRates = listOf(23.976f to "23.976 fps", 24f to "24 fps", 25f to "25 fps", 29.97f to "29.97 fps", 30f to "30 fps", 50f to "50 fps", 59.94f to "59.94 fps", 60f to "60 fps")

/** Watching the audio outputs needs Android 6; these two are only called there. */
@androidx.annotation.RequiresApi(23)
private fun registerAudioWatch(context: Context, handler: Handler, changed: () -> Unit): Any {
    val cb = object : AudioDeviceCallback() { override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) { changed() }; override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) { changed() } }
    (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).registerAudioDeviceCallback(cb, handler)
    return cb
}

@androidx.annotation.RequiresApi(23)
private fun unregisterAudioWatch(context: Context, token: Any) { (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).unregisterAudioDeviceCallback(token as AudioDeviceCallback) }

/**
 * Settings, Diagnostics, Playback capabilities. It reads what the device says it can do and shows it; it plays nothing, changes nothing and is not used when a stream is opened.
 * The profile is built once in the background and kept; it is read again only after the display or the audio output changes, or when the person taps Refresh. Nothing polls.
 */
@Composable
fun PlaybackCapabilitiesGroup(c: AppContainer) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val caps = remember { PlaybackCapabilities.of(context) }
    var version by remember { mutableIntStateOf(0) }
    var result by remember { mutableStateOf<CapabilityResult?>(null) }
    LaunchedEffect(version) { result = caps.get() }
    var details by remember { mutableStateOf(false) }
    var sample by remember { mutableIntStateOf(1) }
    var rate by remember { mutableIntStateOf(1) }
    var msg by remember { mutableStateOf<String?>(null) }

    // A change of display or audio output makes the kept profile out of date: it is read once more, not watched.
    DisposableEffect(Unit) {
        val handler = Handler(Looper.getMainLooper())
        val changed: () -> Unit = { caps.invalidate(); version = version + 1 }
        val audioToken = if (Build.VERSION.SDK_INT >= 23) registerAudioWatch(context, handler, changed) else null
        val displayCb = object : DisplayManager.DisplayListener { override fun onDisplayAdded(id: Int) { changed() }; override fun onDisplayRemoved(id: Int) { changed() }; override fun onDisplayChanged(id: Int) { changed() } }
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        dm.registerDisplayListener(displayCb, handler)
        onDispose { if (Build.VERSION.SDK_INT >= 23 && audioToken != null) unregisterAudioWatch(context, audioToken); dm.unregisterDisplayListener(displayCb) }
    }

    SettingGroup("Playback capabilities", "What this device reports it can do. Nothing here was proven by playing, and nothing here changes how anything plays.") {
        when (val r = result) {
            null -> InfoRow("Reading the device…", "")
            is CapabilityResult.Failed -> InfoRow("Could not be read", "", r.reason)
            is CapabilityResult.Ready -> {
                val p = r.profile
                CapabilityAnalysis.summary(p).forEach { InfoRow(it.title, "", it.text) }
                ActionRow("Read the device again", null, "Refresh", confirm = false) { caps.invalidate(); version++ }
                val (sampleLabel, format) = sampleStreams[sample]
                val advice = remember(p, sample) { CapabilityAdvisor.advise(p, format, Media3DecoderAdapter::preferred) }
                ChoiceRow("Advisor: a stream like", "A suggestion only. Nothing uses it when a stream opens.", sampleStreams.indices.map { it to sampleStreams[it].first }, sample) { sample = it }
                InfoRow("Suggested engine", advice.engine.label + "  ·  " + advice.decoderClass.label, "Confidence ${advice.confidence.label}. " + advice.reasons.joinToString(" ") { it.text })
                advice.warnings.forEach { InfoRow("Note", "", it) }
                advice.evidence.forEach { InfoRow("Evidence", "", it) }
                val current = p.display.current
                ChoiceRow("Frame-rate matching: content", "Diagnostic only. It does not change the Playback setting \u201cMatch the TV's frame rate\u201d.", sampleRates.indices.map { it to sampleRates[it].second }, rate) { rate = it }
                val fr = CapabilityAnalysis.frameRate(sampleRates[rate].first, current, p.display.modes)
                val appSetting by c.settings.matchFrameRate.collectAsState()
                InfoRow(fr.outcome.label, "", fr.note)
                InfoRow("App setting", if (appSetting) "On" else "Off", "Match the TV's frame rate, under Playback. This page never changes it.")
                SettingRow(if (details) "Hide technical details" else "Show technical details", "Display, audio, decoders and the fixed test formats.", if (details) "Shown" else "Hidden") { details = !details }
                if (details) {
                    InfoRow("Device", "${p.device.manufacturer} ${p.device.model}", "Android ${p.device.release} (API ${p.device.sdk})")
                    InfoRow("Memory", "class ${p.memory.memoryClassMb} MB", "Large class ${p.memory.largeMemoryClassMb} MB, ${p.memory.totalMb} MB system RAM (${p.memory.availableMb} MB free), low-RAM flag ${p.memory.lowRamDevice}")
                    InfoRow("Display", current?.let { "${it.width}×${it.height} at ${"%.2f".format(it.refreshRate)} Hz" } ?: "Unknown", "Interface ${p.display.uiWidth}×${p.display.uiHeight}. Other refresh rates: ${p.display.alternativeRefreshRatesReported.label}")
                    InfoRow("Display HDR (${p.display.hdrSource})", "", "HDR10 ${p.display.hdr10.label}. HDR10+ ${p.display.hdr10Plus.label}. HLG ${p.display.hlg.label}. Dolby Vision ${p.display.dolbyVision.label}.")
                    if (p.audio.routes.isEmpty()) InfoRow("Audio output", "None reported")
                    p.audio.routes.forEach { InfoRow("Audio: ${it.type}", it.product, "Encodings: " + it.encodings.joinToString(", ").ifBlank { "none listed" } + ". Not verified by playback.") }
                    p.audio.direct?.let { m -> InfoRow("Direct playback by this route", "", m.entries.joinToString(". ") { "${it.key}: ${it.value.label}" } + ".") } ?: InfoRow("Direct playback by this route", Reported.NOT_AVAILABLE.label)
                    InfoRow("Video decoders", "${p.decoders.size}", "Listed below by type. The instance number is an upper bound the decoder advertises, not how many videos can play at once.")
                    p.decoders.sortedWith(compareBy({ it.mime }, { !it.isHardware }, { it.name })).take(60).forEach { x ->
                        InfoRow(x.name, if (x.isHardware) "Hardware" else "Software", "${x.mime}. Up to ${x.maxWidth ?: "?"}×${x.maxHeight ?: "?"} at ${x.maxFrameRate ?: "?"} fps. Instances (upper bound): ${x.maxInstances ?: "unknown"}. Secure ${x.secure.label.lowercase()}. Tunneled ${x.tunneled.label.lowercase()}.")
                    }
                }
                ActionRow("Save a safe report", "The report has no addresses, logins, titles or account data.", "Save", confirm = false) {
                    scope.launch {
                        val text = CapabilityReport.text(p, sampleStreams.map { (label, f) -> label to CapabilityAdvisor.advise(p, f, Media3DecoderAdapter::preferred) })
                        val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, "reports").also { it.mkdirs() }
                        val f = File(dir, "capabilities-" + java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(Date()) + ".txt"); f.writeText(text)
                        msg = "Saved: ${f.absolutePath.substringAfter("Android/")}"
                    }
                }
                ResultLine(msg)
            }
        }
    }
}
