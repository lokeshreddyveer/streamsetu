package app.streamsetu.tv.sports.multiview

import android.app.ActivityManager
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

/** One video decoder the device reports. [maxInstances] is 0 when the platform does not say. */
data class HardwareDecoder(val mime: String, val secure: Boolean, val maxInstances: Int)

/** What the device reports about itself. Read from the platform; nothing here comes from a model name and nothing is learned by playing a stream. */
data class DeviceFacts(val lowRam: Boolean, val memoryClassMb: Int, val cores: Int, val decoders: List<HardwareDecoder>)

/**
 * How many pictures this device is allowed to show at once. The result is an upper bound, not a promise: [MultiviewCapability.noteAllocationFailure] lowers it for the rest of the session
 * when a decoder could not be allocated.
 *
 *  - no hardware H.264 decoder for ordinary (non-secure) streams: one picture. Several pictures are never decoded in software.
 *  - a low-memory device, a small memory class or four cores or fewer: two.
 *  - a mid-sized memory class: three.
 *  - otherwise four. Never more than the decoder says it can run at once.
 */
object TileLimitPolicy {
    const val MAX = 4

    fun limit(f: DeviceFacts): Int {
        val h264 = f.decoders.filter { it.mime == "video/avc" && !it.secure }
        if (h264.isEmpty()) return 1
        val instances = h264.maxOf { if (it.maxInstances > 0) it.maxInstances else 2 }          // unknown: assume two, the smallest useful answer
        val cap = when {
            f.lowRam || f.memoryClassMb <= 192 || f.cores <= 4 -> 2
            f.memoryClassMb < 256 -> 3
            else -> MAX
        }
        return minOf(cap, instances).coerceAtLeast(1)
    }

    /** Whether a feed whose codec is known can be shown at all. A stream whose codec has no hardware decoder here is refused rather than software-decoded beside other pictures. */
    fun canDecode(f: DeviceFacts, mime: String): Boolean = f.decoders.any { it.mime == mime && !it.secure }
}

/** The largest picture a tile may decode. A quarter of the screen has no use for a 4K stream, and several decoders at full size are what freeze a small device. */
object TileVideoCap {
    fun forCount(tiles: Int): Pair<Int, Int> = if (tiles >= 4) 960 to 540 else 1280 to 720
}

/** The decoder limit for this process: the policy's answer for the device, lowered by what actually happened. */
class MultiviewCapability(facts: () -> DeviceFacts) {
    @Volatile private var learned = TileLimitPolicy.MAX
    private val read: DeviceFacts by lazy(facts)                  // read once: the platform is not asked again for every report
    private val device: Int by lazy { TileLimitPolicy.limit(read) }

    fun deviceFacts(): DeviceFacts = read
    /** What the device allows, before anything went wrong. */
    fun deviceLimit(): Int = device
    /** What may be tried now. */
    fun usableLimit(): Int = minOf(device, learned)

    /** A decoder could not be allocated while [working] pictures were playing: that many is the most this session will try again. */
    fun noteAllocationFailure(working: Int) { learned = minOf(learned, working.coerceAtLeast(1)) }

    companion object {
        /** Reads the platform. No stream is started and no network is used. */
        fun read(context: Context): DeviceFacts {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val decoders = runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder && isHardware(it) }.flatMap { info ->
                    info.supportedTypes.filter { it.startsWith("video/") }.map { mime ->
                        val caps = runCatching { info.getCapabilitiesForType(mime) }.getOrNull()
                        HardwareDecoder(mime.lowercase(), info.name.endsWith(".secure", true), instances(caps))
                    }
                }
            }.getOrDefault(emptyList())
            return DeviceFacts(am.isLowRamDevice, am.memoryClass, Runtime.getRuntime().availableProcessors(), decoders)
        }

        private fun isHardware(info: MediaCodecInfo): Boolean = if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated else hardwareByName(info.name)

        /** Before Android 10 the platform does not say; a decoder written in software carries the platform's own name prefixes. */
        fun hardwareByName(name: String): Boolean = !name.startsWith("OMX.google", true) && !name.startsWith("c2.android", true) && !name.startsWith("c2.google", true)

        /** Before Android 6 the platform does not say how many instances a decoder can run, so none is claimed (the policy then assumes two). */
        fun instancesFor(sdk: Int, reported: Int): Int = if (sdk >= 23) reported else 0

        private fun instances(caps: MediaCodecInfo.CodecCapabilities?): Int = if (caps != null && Build.VERSION.SDK_INT >= 23) instancesFor(Build.VERSION.SDK_INT, caps.maxSupportedInstances) else 0
    }
}

/** What an existing set of channels (the channel that was playing when Multi-View was opened) needs when this device can show fewer. The set itself is never changed or shortened here. */
sealed interface PresetPlan {
    data object Empty : PresetPlan
    data class Ready(val entries: List<MultiviewEntry>) : PresetPlan
    /** More than the device can show: the person chooses which to keep. */
    data class NeedsChoice(val limit: Int, val entries: List<MultiviewEntry>) : PresetPlan
}

object PresetFit {
    fun plan(preset: List<MultiviewEntry>, limit: Int): PresetPlan = when {
        preset.isEmpty() -> PresetPlan.Empty
        preset.size <= limit -> PresetPlan.Ready(preset)
        else -> PresetPlan.NeedsChoice(limit, preset)
    }
}
