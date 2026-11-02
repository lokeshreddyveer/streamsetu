package app.streamsetu.tv.diagnostics.capability

/** A stream described only by its format: no address, no provider, no title and nothing from the library. */
data class StreamFormat(
    val container: String?, val videoMime: String?, val codecString: String? = null, val profile: Int? = null, val level: Int? = null,
    val width: Int?, val height: Int?, val frameRate: Float? = null, val bitDepth: Int? = null, val hdr: String? = null,
    val secureRequired: Boolean = false, val audioMime: String? = null, val channels: Int? = null, val subtitleType: String? = null,
)

enum class SuggestedEngine(val label: String) { EXOPLAYER("ExoPlayer"), MPV("mpv"), UNKNOWN("Unknown") }
enum class DecoderClass(val label: String) { HARDWARE_PREFERRED("Hardware preferred"), SOFTWARE_FALLBACK("Software fallback"), UNKNOWN("Unknown") }
enum class Confidence(val label: String) { HIGH("High"), MEDIUM("Medium"), LOW("Low") }

/** Fixed reason codes, so a report says the same thing every time. */
enum class Reason(val text: String) {
    HW_DECODER_REPORTS_FORMAT("A hardware decoder reports it accepts this format."),
    ONLY_SOFTWARE_DECODER_REPORTS_FORMAT("Only a software decoder reports it accepts this format."),
    NO_DECODER_REPORTS_FORMAT("No decoder of this device reports it accepts this format."),
    CONTAINER_NOT_IN_EXOPLAYER_PATH("The container is not one the normal ExoPlayer path reads."),
    CONTAINER_IN_EXOPLAYER_PATH("The container is one the normal ExoPlayer path reads."),
    CONTRADICTORY_REPORTS("A decoder's reports contradict each other."),
    FORMAT_DETAILS_MISSING("The format does not say enough (type or size) to judge."),
    NO_DECODER_INVENTORY("This device reported no decoders."),
    SECURE_DECODER_REQUIRED("A secure decoder is required."),
}

data class Advice(
    val engine: SuggestedEngine, val decoderClass: DecoderClass, val confidence: Confidence, val reasons: List<Reason>, val warnings: List<String>, val evidence: List<String>,
)

/**
 * Says which engine and kind of decoder a format would probably suit on this device. It reads a [PlaybackCapabilityProfile] and a [StreamFormat] and nothing else: no player, no
 * controller, no settings. The real engine choice never calls it. [preferredDecoder] is how the page shows which decoder Media3 would pick (see Media3DecoderAdapter); it only names one.
 */
object CapabilityAdvisor {
    /** Containers the normal ExoPlayer path does not read. mpv reads them. */
    private val notForExoPlayer = setOf("avi", "wmv", "asf", "rm", "rmvb", "divx", "vob", "iso", "mpeg-ps-dvd")

    fun advise(profile: PlaybackCapabilityProfile, f: StreamFormat, preferredDecoder: (mime: String, secure: Boolean) -> String? = { _, _ -> null }): Advice {
        val reasons = ArrayList<Reason>(); val warnings = ArrayList<String>(); val evidence = ArrayList<String>()
        val mime = f.videoMime
        if (mime.isNullOrBlank() || f.width == null || f.height == null) return Advice(SuggestedEngine.UNKNOWN, DecoderClass.UNKNOWN, Confidence.LOW, listOf(Reason.FORMAT_DETAILS_MISSING), emptyList(), emptyList())
        if (profile.decoders.isEmpty()) return Advice(SuggestedEngine.UNKNOWN, DecoderClass.UNKNOWN, Confidence.LOW, listOf(Reason.NO_DECODER_INVENTORY), emptyList(), emptyList())

        val container = f.container?.lowercase()
        val containerOk = container == null || container !in notForExoPlayer
        if (container != null) reasons += if (containerOk) Reason.CONTAINER_IN_EXOPLAYER_PATH else Reason.CONTAINER_NOT_IN_EXOPLAYER_PATH
        if (f.secureRequired) reasons += Reason.SECURE_DECODER_REQUIRED

        val candidates = profile.decodersFor(mime)
        if (candidates.any { contradicts(it) }) {
            return Advice(SuggestedEngine.UNKNOWN, DecoderClass.UNKNOWN, Confidence.LOW, reasons + Reason.CONTRADICTORY_REPORTS, listOf("Treat this device's report for this codec with care."), evidence)
        }
        val accepting = candidates.filter { accepts(it, f) }
        val hw = accepting.filter { it.isHardware }
        val sw = accepting.filter { it.isSoftware }
        preferredDecoder(mime, f.secureRequired)?.let { evidence += "Media3 would prefer the decoder “$it”." }
        accepting.take(4).forEach { evidence += "${it.name}: ${if (it.isHardware) "hardware" else "software"}" }

        return when {
            !containerOk -> {
                reasons += if (hw.isNotEmpty()) Reason.HW_DECODER_REPORTS_FORMAT else if (sw.isNotEmpty()) Reason.ONLY_SOFTWARE_DECODER_REPORTS_FORMAT else Reason.NO_DECODER_REPORTS_FORMAT
                Advice(SuggestedEngine.MPV, if (hw.isNotEmpty()) DecoderClass.HARDWARE_PREFERRED else DecoderClass.SOFTWARE_FALLBACK, Confidence.MEDIUM, reasons, warnings, evidence)
            }
            hw.isNotEmpty() -> Advice(SuggestedEngine.EXOPLAYER, DecoderClass.HARDWARE_PREFERRED, Confidence.HIGH, reasons + Reason.HW_DECODER_REPORTS_FORMAT, warnings, evidence)
            sw.isNotEmpty() -> {
                warnings += "Only a software decoder reports support, which may not keep up at this size and rate."
                Advice(SuggestedEngine.EXOPLAYER, DecoderClass.SOFTWARE_FALLBACK, Confidence.MEDIUM, reasons + Reason.ONLY_SOFTWARE_DECODER_REPORTS_FORMAT, warnings, evidence)
            }
            else -> {
                warnings += "No decoder of this device reports it accepts this format."
                Advice(SuggestedEngine.MPV, DecoderClass.SOFTWARE_FALLBACK, Confidence.LOW, reasons + Reason.NO_DECODER_REPORTS_FORMAT, warnings, evidence)
            }
        }
    }

    /** Whether one decoder's declared limits take the whole format (only the limits it actually declares are held against it). */
    internal fun accepts(d: DecoderInfo, f: StreamFormat): Boolean {
        val w = f.width ?: return false; val h = f.height ?: return false
        if (d.maxWidth != null && w > d.maxWidth) return false
        if (d.maxHeight != null && h > d.maxHeight) return false
        // A decoder may be declared for the portrait orientation: the long side against the long side.
        if (d.maxWidth != null && d.maxHeight != null && maxOf(w, h) > maxOf(d.maxWidth, d.maxHeight)) return false
        val fps = f.frameRate
        if (fps != null && d.maxFrameRate != null && fps > d.maxFrameRate + 0.5f) return false
        if (f.profile != null && d.profileLevels.isNotEmpty()) {
            val p = d.profileLevels.filter { it.profile == f.profile }
            if (p.isEmpty()) return false
            if (f.level != null && p.none { it.level >= f.level }) return false
        }
        if (f.secureRequired && d.secure != Reported.SUPPORTED) return false
        return true
    }

    /** A decoder that says yes to a fixture bigger than the size it declares it can do, or no to one well inside it. */
    internal fun contradicts(d: DecoderInfo): Boolean = d.formats.any { (id, answer) ->
        val fx = DiagnosticFormats.byId(id) ?: return@any false
        val big = d.maxWidth != null && d.maxHeight != null && maxOf(fx.width, fx.height) > maxOf(d.maxWidth, d.maxHeight)
        answer == Reported.SUPPORTED && big
    }
}
