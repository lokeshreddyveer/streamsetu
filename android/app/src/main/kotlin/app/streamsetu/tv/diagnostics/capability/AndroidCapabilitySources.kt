package app.streamsetu.tv.diagnostics.capability

import android.app.ActivityManager
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Display

/** Where the facts come from. A test supplies its own; the app reads the platform. */
interface CapabilitySources {
    fun device(): DeviceIdentity
    fun memory(): MemoryFacts
    fun display(): DisplayFacts
    fun audio(): AudioFacts
    fun decoders(): List<DecoderInfo>
}

/**
 * Reads the platform and nothing else. It asks lists and capability objects questions; it never creates a decoder, a player, an audio track or a surface, never changes a display
 * mode, never calls setFrameRate and never contacts a provider. Each part is read separately, so a device that fails one still reports the others.
 */
@android.annotation.SuppressLint("NewApi")          // every call that needs a newer Android is guarded by the SDK_INT check just above it
class AndroidCapabilitySources(private val context: Context) : CapabilitySources {
    private val app = context.applicationContext

    override fun device() = DeviceIdentity(
        Build.VERSION.SDK_INT, Build.VERSION.RELEASE.orEmpty(), Build.MANUFACTURER.orEmpty(), Build.MODEL.orEmpty(), Build.DEVICE.orEmpty(),
        Build.MANUFACTURER.equals("Amazon", ignoreCase = true) || app.packageManager.hasSystemFeature("amazon.hardware.fire_tv"),
    )

    override fun memory(): MemoryFacts {
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        return MemoryFacts(am.memoryClass, am.largeMemoryClass, am.isLowRamDevice, info.totalMem / MB, info.availMem / MB)
    }

    @Suppress("DEPRECATION")
    override fun display(): DisplayFacts {
        val dm = app.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY) ?: return emptyDisplay()
        val sdk = Build.VERSION.SDK_INT
        fun modeOf(m: Display.Mode) = DisplayMode(
            m.modeId, m.physicalWidth, m.physicalHeight, m.refreshRate,
            if (sdk >= 31) m.alternativeRefreshRates.toList() else null,
            if (sdk >= 34) m.supportedHdrTypes.map(::hdrName) else null,
        )
        val current = if (sdk >= 23) d.mode?.let(::modeOf) else null
        val modes = if (sdk >= 23) d.supportedModes.orEmpty().map(::modeOf) else emptyList()
        val size = android.graphics.Point().also { d.getRealSize(it) }
        val ui = app.resources.displayMetrics
        // Android 14 reports HDR types per display mode; before that the display reports them once, and before Android 7 not at all.
        val types: List<String>?; val source: String; var maxLum: Float? = null; var avgLum: Float? = null; var minLum: Float? = null
        when {
            sdk >= 34 && current?.hdrTypes != null -> { types = (current.hdrTypes); source = "current display mode" }
            sdk >= 24 -> {
                val caps = d.hdrCapabilities
                types = caps?.supportedHdrTypes?.map(::hdrName)
                maxLum = caps?.desiredMaxLuminance?.takeIf { it > 0f }; avgLum = caps?.desiredMaxAverageLuminance?.takeIf { it > 0f }; minLum = caps?.desiredMinLuminance?.takeIf { it > 0f }
                source = "display"
            }
            else -> { types = null; source = "not available on this Android version" }
        }
        fun has(name: String) = if (types == null) (if (sdk >= 24) Reported.UNKNOWN else Reported.NOT_AVAILABLE) else if (name in types) Reported.SUPPORTED else Reported.UNSUPPORTED
        return DisplayFacts(current ?: DisplayMode(0, size.x, size.y, d.refreshRate, null, null), modes, has("HDR10"), has("HDR10+"), has("HLG"), has("Dolby Vision"), maxLum, avgLum, minLum, source, ui.widthPixels, ui.heightPixels)
    }

    private fun emptyDisplay() = DisplayFacts(null, emptyList(), Reported.UNKNOWN, Reported.UNKNOWN, Reported.UNKNOWN, Reported.UNKNOWN, null, null, null, "unavailable", 0, 0)

    private fun hdrName(t: Int) = when (t) { Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "Dolby Vision"; Display.HdrCapabilities.HDR_TYPE_HDR10 -> "HDR10"; Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "HDR10+"; Display.HdrCapabilities.HDR_TYPE_HLG -> "HLG"; else -> "type $t" }

    override fun audio(): AudioFacts {
        if (Build.VERSION.SDK_INT < 23) return AudioFacts(emptyList(), null)
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val routes = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { d ->
            AudioRoute(
                routeType(d.type), d.productName?.toString().orEmpty(), d.encodings.map(::encodingName), d.channelCounts.toList(), d.sampleRates.toList(), d.channelMasks.toList(),
                if (Build.VERSION.SDK_INT >= 34) d.encapsulationModes.map { if (it == AudioTrackEncapsulationElementary) "Elementary stream" else if (it == AudioTrackEncapsulationHandle) "Handle" else "Mode $it" } else emptyList(),
            )
        }
        return AudioFacts(routes, if (Build.VERSION.SDK_INT >= 33) directPlayback() else null)
    }

    private fun directPlayback(): Map<String, Reported> {
        val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
        fun ask(encoding: Int, mask: Int, rate: Int = 48000): Reported = runCatching {
            val support = AudioManager.getDirectPlaybackSupport(AudioFormat.Builder().setEncoding(encoding).setSampleRate(rate).setChannelMask(mask).build(), attrs)
            if (support == 0) Reported.UNSUPPORTED else Reported.SUPPORTED          // 0 is "not supported"; offload or bitstream is "the route says so"
        }.getOrDefault(Reported.UNKNOWN)
        val five1 = AudioFormat.CHANNEL_OUT_5POINT1
        return linkedMapOf(
            "PCM 5.1" to ask(AudioFormat.ENCODING_PCM_16BIT, five1), "AC-3" to ask(AudioFormat.ENCODING_AC3, five1), "E-AC-3" to ask(AudioFormat.ENCODING_E_AC3, five1),
            "E-AC-3 JOC" to ask(AudioFormat.ENCODING_E_AC3_JOC, five1), "DTS" to ask(AudioFormat.ENCODING_DTS, five1), "DTS-HD" to ask(AudioFormat.ENCODING_DTS_HD, five1),
            "TrueHD" to ask(AudioFormat.ENCODING_DOLBY_TRUEHD, five1, 192000),
        )
    }

    private fun routeType(t: Int) = when (t) {
        AudioDeviceInfo.TYPE_HDMI -> "HDMI"; AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI ARC"; AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "TV or device speaker"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth"; AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired"; AudioDeviceInfo.TYPE_LINE_ANALOG -> "Analog"; AudioDeviceInfo.TYPE_AUX_LINE -> "Aux"
        else -> "Other ($t)"
    }

    private fun encodingName(e: Int) = when (e) {
        AudioFormat.ENCODING_PCM_16BIT -> "PCM 16"; AudioFormat.ENCODING_PCM_8BIT -> "PCM 8"; AudioFormat.ENCODING_PCM_FLOAT -> "PCM float"; AudioFormat.ENCODING_AC3 -> "AC-3"
        AudioFormat.ENCODING_E_AC3 -> "E-AC-3"; AudioFormat.ENCODING_DTS -> "DTS"; AudioFormat.ENCODING_DTS_HD -> "DTS-HD"; AudioFormat.ENCODING_DOLBY_TRUEHD -> "TrueHD"
        AudioFormat.ENCODING_AAC_LC -> "AAC"; AudioFormat.ENCODING_E_AC3_JOC -> "E-AC-3 JOC"; AudioFormat.ENCODING_IEC61937 -> "IEC 61937"; else -> "Encoding $e"
    }

    /** Every video decoder the platform lists, asked what it reports. Asking does not start one. */
    override fun decoders(): List<DecoderInfo> {
        val out = ArrayList<DecoderInfo>()
        val sdk = Build.VERSION.SDK_INT
        for (info in MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos) {
            if (info.isEncoder) continue
            for (type in info.supportedTypes) {
                if (!type.startsWith("video/", ignoreCase = true)) continue
                val caps = runCatching { info.getCapabilitiesForType(type) }.getOrNull() ?: continue
                val v = caps.videoCapabilities
                fun feature(f: String) = runCatching { caps.isFeatureSupported(f) }.map { if (it) Reported.SUPPORTED else Reported.UNSUPPORTED }.getOrDefault(Reported.UNKNOWN)
                val formats = LinkedHashMap<String, Reported>()
                for (fx in DiagnosticFormats.all) {
                    if (!fx.mime.equals(type, ignoreCase = true)) continue
                    formats[fx.id] = runCatching {
                        val f = MediaFormat.createVideoFormat(type, fx.width, fx.height).apply { setInteger(MediaFormat.KEY_FRAME_RATE, fx.frameRate); fx.profile?.let { setInteger(MediaFormat.KEY_PROFILE, it) } }
                        if (caps.isFormatSupported(f)) Reported.SUPPORTED else Reported.UNSUPPORTED
                    }.getOrDefault(Reported.UNKNOWN)
                }
                out += DecoderInfo(
                    name = info.name, mime = type,
                    hardware = if (sdk >= 29) info.isHardwareAccelerated else null, softwareOnly = if (sdk >= 29) info.isSoftwareOnly else null,
                    vendor = if (sdk >= 29) info.isVendor else null, alias = if (sdk >= 29) info.isAlias else null,
                    profileLevels = caps.profileLevels.orEmpty().map { ProfileLevel(it.profile, it.level) },
                    minWidth = v?.supportedWidths?.lower, maxWidth = v?.supportedWidths?.upper, minHeight = v?.supportedHeights?.lower, maxHeight = v?.supportedHeights?.upper,
                    minFrameRate = v?.supportedFrameRates?.lower, maxFrameRate = v?.supportedFrameRates?.upper,
                    minBitrate = v?.bitrateRange?.lower, maxBitrate = v?.bitrateRange?.upper,
                    maxInstances = if (sdk >= 23) caps.maxSupportedInstances.takeIf { it > 0 } else null,
                    adaptive = feature(MediaCodecInfo.CodecCapabilities.FEATURE_AdaptivePlayback), secure = feature(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback),
                    tunneled = feature(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback), formats = formats,
                )
            }
        }
        return out
    }

    private companion object {
        const val MB = 1024L * 1024L
        // AudioTrack's encapsulation modes (Android 10): written as numbers so this file does not touch AudioTrack at all.
        const val AudioTrackEncapsulationElementary = 1
        const val AudioTrackEncapsulationHandle = 2
    }
}
