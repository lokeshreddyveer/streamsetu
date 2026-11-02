package app.streamsetu.tv.diagnostics.capability

import kotlin.math.abs
import kotlin.math.roundToInt

/** One line of the summary: what is reported, never what is proven. */
data class SummaryLine(val title: String, val text: String)

/**
 * Turns the raw facts into the short statements the Diagnostics page opens with. Display support and decoder support are kept apart: a screen that reports Dolby Vision says nothing
 * about the decoder profiles, and the other way round. Every line says "reported", and none says the thing was played.
 */
object CapabilityAnalysis {
    const val NOT_VERIFIED = "playback not verified"

    fun summary(p: PlaybackCapabilityProfile): List<SummaryLine> = buildList {
        add(hevc4k60(p)); add(dolbyVision(p)); add(eac3(p)); add(tunneling(p))
        add(SummaryLine("Frame-rate matching", "Diagnostic only: what the display reports. The app's own setting is under Playback and is not changed here."))
    }

    private fun hevc4k60(p: PlaybackCapabilityProfile): SummaryLine {
        val id = "hevc-main10-2160p60"
        val hevc = p.decodersFor("video/hevc")
        val answers = hevc.map { it to (it.formats[id] ?: Reported.UNKNOWN) }
        val text = when {
            p.decoders.isEmpty() -> "Unknown: this device reported no decoders."
            hevc.isEmpty() -> "Reported unsupported: no HEVC decoder is listed."
            answers.any { (d, r) -> r.yes && d.isHardware } -> "Reported supported by a hardware decoder ($NOT_VERIFIED)."
            answers.any { (_, r) -> r.yes } -> "Reported supported by a software decoder only ($NOT_VERIFIED)."
            answers.all { (_, r) -> r == Reported.UNSUPPORTED } -> "Reported unsupported by every HEVC decoder."
            else -> "Unknown."
        }
        return SummaryLine("HEVC Main10 4K60", text)
    }

    /** What the display says and what the decoders say, as two facts. */
    fun dolbyVision(p: PlaybackCapabilityProfile): SummaryLine {
        val display = p.display.dolbyVision
        val dv = p.decodersFor(DiagnosticFormats.DOLBY_VISION_MIME)
        val decoder = when { p.decoders.isEmpty() -> Reported.UNKNOWN; dv.any { it.profileLevels.isNotEmpty() } -> Reported.SUPPORTED; else -> Reported.UNSUPPORTED }
        val profiles = dv.flatMap { it.profileLevels }.map { it.profile }.distinct().sorted()
        val text = "Display: ${yn(display)}. Decoder: ${yn(decoder)}" + (if (profiles.isNotEmpty()) " (profile numbers ${profiles.joinToString(", ")})" else "") + ". Playback verified: No."
        return SummaryLine("Dolby Vision", text)
    }

    private fun eac3(p: PlaybackCapabilityProfile): SummaryLine {
        val direct = p.audio.direct
        val text = when {
            direct != null -> "Direct playback: ${(direct["E-AC-3"] ?: Reported.UNKNOWN).label.lowercase()} by the current output ($NOT_VERIFIED)."
            p.audio.routes.any { r -> r.encodings.any { it.contains("E-AC-3", true) || it.contains("EAC3", true) } } -> "The current output lists E-AC-3 as an encoding ($NOT_VERIFIED)."
            p.audio.routes.isEmpty() -> "Unknown: no audio output was reported."
            else -> "Unknown on this Android version; the current output does not list E-AC-3."
        }
        return SummaryLine("E-AC-3 direct playback", text)
    }

    private fun tunneling(p: PlaybackCapabilityProfile): SummaryLine {
        val n = p.decoders.filter { it.tunneled == Reported.SUPPORTED }
        val text = if (n.isEmpty()) "No decoder reports it. Disabled." else "Reported by ${n.size} decoder${if (n.size == 1) "" else "s"}; not verified. Disabled."
        return SummaryLine("Tunneling", text)
    }

    private fun yn(r: Reported) = when (r) { Reported.SUPPORTED -> "reported"; Reported.UNSUPPORTED -> "not reported"; else -> "unknown" }

    // ---- Frame-rate matching: what Android would be asked, never done ----

    enum class FrameRateOutcome(val label: String) {
        POSSIBLE_SEAMLESS_MATCH("Possible seamless match."), NON_SEAMLESS_SWITCH_REQUIRED("Would require a non-seamless display switch."),
        NO_USEFUL_ALTERNATIVE("No useful alternative reported."), UNKNOWN("Unknown."),
    }
    data class FrameRateAdvice(val outcome: FrameRateOutcome, val matchingRate: Float?, val note: String)

    /** True when [rate] is a whole multiple (1 to 5) of [content], within half a percent: 24 in 48 or 120, 23.976 in 47.952 and 119.88. */
    fun matches(content: Float, rate: Float): Boolean {
        if (content <= 0f || rate <= 0f) return false
        val ratio = rate / content
        val whole = ratio.roundToInt()
        return whole in 1..5 && abs(ratio - whole) / whole < 0.005f
    }

    fun frameRate(contentFps: Float?, current: DisplayMode?, modes: List<DisplayMode>): FrameRateAdvice {
        if (contentFps == null || contentFps <= 0f || current == null) return FrameRateAdvice(FrameRateOutcome.UNKNOWN, null, "The content's frame rate or the display's current mode is not known.")
        if (matches(contentFps, current.refreshRate)) return FrameRateAdvice(FrameRateOutcome.NO_USEFUL_ALTERNATIVE, current.refreshRate, "The display already runs at a rate that fits ${"%.3f".format(contentFps)} fps.")
        val sameSize = modes.filter { it.width == current.width && it.height == current.height && matches(contentFps, it.refreshRate) }
        if (sameSize.isEmpty()) return FrameRateAdvice(FrameRateOutcome.NO_USEFUL_ALTERNATIVE, null, "No mode of this size reports a rate that fits ${"%.3f".format(contentFps)} fps.")
        val seamless = current.alternativeRefreshRates
            ?: return FrameRateAdvice(FrameRateOutcome.UNKNOWN, sameSize.first().refreshRate, "A matching mode exists, but this Android version cannot say whether switching to it is seamless.")
        val easy = sameSize.firstOrNull { m -> seamless.any { abs(it - m.refreshRate) < 0.01f } }
        return if (easy != null) FrameRateAdvice(FrameRateOutcome.POSSIBLE_SEAMLESS_MATCH, easy.refreshRate, "The display lists ${"%.3f".format(easy.refreshRate)} Hz as reachable without a visible switch. Android may still refuse a request.")
        else FrameRateAdvice(FrameRateOutcome.NON_SEAMLESS_SWITCH_REQUIRED, sameSize.first().refreshRate, "A matching mode exists but is not listed as seamless: the screen would blank briefly.")
    }
}
