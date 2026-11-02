package app.streamsetu.tv.diagnostics.capability

/**
 * What a device reports about playback, as plain values. Nothing here is a measurement: every answer is what the platform says, and none of it is proven by playing anything.
 * This package only reads. It never creates a decoder, a player, an audio track or a surface, never changes a display mode and is never consulted by the real engine choice.
 */
enum class Reported(val label: String) {
    SUPPORTED("Reported supported"), UNSUPPORTED("Reported unsupported"), UNKNOWN("Unknown"), NOT_AVAILABLE("Not available on this Android version");
    val yes get() = this == SUPPORTED
}

data class DeviceIdentity(val sdk: Int, val release: String, val manufacturer: String, val model: String, val device: String, val isFireTv: Boolean)
data class MemoryFacts(val memoryClassMb: Int, val largeMemoryClassMb: Int, val lowRamDevice: Boolean, val totalMb: Long, val availableMb: Long)

/** One profile and level a decoder declares, as the platform's raw numbers (see MediaCodecInfo.CodecProfileLevel). */
data class ProfileLevel(val profile: Int, val level: Int)

/** What one decoder reports for one video type. [maxInstances] is an upper bound the decoder advertises, not a count of videos the device can play (null: not reported). */
data class DecoderInfo(
    val name: String, val mime: String,
    val hardware: Boolean?, val softwareOnly: Boolean?, val vendor: Boolean?, val alias: Boolean?,
    val profileLevels: List<ProfileLevel>,
    val minWidth: Int?, val maxWidth: Int?, val minHeight: Int?, val maxHeight: Int?,
    val minFrameRate: Int?, val maxFrameRate: Int?, val minBitrate: Int?, val maxBitrate: Int?,
    val maxInstances: Int?,
    val adaptive: Reported, val secure: Reported, val tunneled: Reported,
    /** For each fixed diagnostic format (see [DiagnosticFormats]) what the decoder answers when asked whether it accepts it. Asking does not start the decoder. */
    val formats: Map<String, Reported>,
) {
    /** Hardware when the platform says so; when it cannot say (before Android 10) a decoder whose name does not look like a software one counts as hardware. */
    val isHardware get() = hardware ?: (softwareOnly == false && !name.lowercase().let { it.startsWith("omx.google.") || it.startsWith("c2.android.") })
    val isSoftware get() = softwareOnly ?: !isHardware
}

data class DisplayMode(val id: Int, val width: Int, val height: Int, val refreshRate: Float, val alternativeRefreshRates: List<Float>?, val hdrTypes: List<String>?)

/** What the screen reports. It says nothing about what the decoders can do. */
data class DisplayFacts(
    val current: DisplayMode?, val modes: List<DisplayMode>,
    val hdr10: Reported, val hdr10Plus: Reported, val hlg: Reported, val dolbyVision: Reported,
    val maxLuminance: Float?, val maxAverageLuminance: Float?, val minLuminance: Float?,
    val hdrSource: String, val uiWidth: Int, val uiHeight: Int,
) {
    val alternativeRefreshRatesReported: Reported get() = when {
        modes.isEmpty() -> Reported.UNKNOWN
        modes.map { it.refreshRate }.distinct().size > 1 -> Reported.SUPPORTED
        else -> Reported.UNSUPPORTED
    }
}

data class AudioRoute(
    val type: String, val product: String, val encodings: List<String>, val channelCounts: List<Int>, val sampleRates: List<Int>, val channelMasks: List<Int>, val encapsulationModes: List<String>,
)

/** What the current outputs report, and (from Android 13) whether the route says it can play each fixed fixture directly. [direct] is null before Android 13. */
data class AudioFacts(val routes: List<AudioRoute>, val direct: Map<String, Reported>?)

data class PlaybackCapabilityProfile(
    val device: DeviceIdentity, val memory: MemoryFacts, val display: DisplayFacts, val audio: AudioFacts, val decoders: List<DecoderInfo>, val builtAtMs: Long,
) {
    /** The decoders that report a given video type. */
    fun decodersFor(mime: String) = decoders.filter { it.mime.equals(mime, ignoreCase = true) }
}

/** The fixed video formats every decoder is asked about. Queries only. */
data class DiagnosticFormat(val id: String, val label: String, val mime: String, val width: Int, val height: Int, val frameRate: Int, val profile: Int? = null, val bitDepth: Int = 8)

object DiagnosticFormats {
    // Profile numbers are those of MediaCodecInfo.CodecProfileLevel: AVCProfileHigh 8, HEVCProfileMain 1, HEVCProfileMain10 2, VP9Profile0 1, VP9Profile2 4, AV1ProfileMain8 1, AV1ProfileMain10 2.
    val all = listOf(
        DiagnosticFormat("avc-1080p30", "H.264 1080p30 High", "video/avc", 1920, 1080, 30, 8),
        DiagnosticFormat("avc-1080p60", "H.264 1080p60 High", "video/avc", 1920, 1080, 60, 8),
        DiagnosticFormat("avc-2160p30", "H.264 2160p30", "video/avc", 3840, 2160, 30, 8),
        DiagnosticFormat("hevc-1080p60", "HEVC Main 1080p60", "video/hevc", 1920, 1080, 60, 1),
        DiagnosticFormat("hevc-main10-2160p30", "HEVC Main10 2160p30", "video/hevc", 3840, 2160, 30, 2, 10),
        DiagnosticFormat("hevc-main10-2160p60", "HEVC Main10 2160p60", "video/hevc", 3840, 2160, 60, 2, 10),
        DiagnosticFormat("vp9-1080p60", "VP9 Profile 0 1080p60", "video/x-vnd.on2.vp9", 1920, 1080, 60, 1),
        DiagnosticFormat("vp9-p2-2160p60", "VP9 Profile 2 2160p60", "video/x-vnd.on2.vp9", 3840, 2160, 60, 4, 10),
        DiagnosticFormat("av1-1080p60", "AV1 Main 1080p60", "video/av01", 1920, 1080, 60, 1),
        DiagnosticFormat("av1-main10-2160p60", "AV1 Main10 2160p60", "video/av01", 3840, 2160, 60, 2, 10),
    )
    fun byId(id: String) = all.firstOrNull { it.id == id }
    const val DOLBY_VISION_MIME = "video/dolby-vision"
}
