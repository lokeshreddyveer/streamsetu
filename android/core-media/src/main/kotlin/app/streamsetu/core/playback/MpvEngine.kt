package app.streamsetu.core.playback

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import dev.jdtech.mpv.MPVLib

/**
 * MPV (libmpv): plays what ExoPlayer is poor at (MKV with AC3/DTS audio, AVI, RTSP, odd containers), like the Mac app's MPV engine.
 * libmpv is one process-wide instance, so there is only ever one MPV engine.
 */
class MpvEngine(context: Context) : PlayerEngine, MPVLib.EventObserver, SurfaceHolder.Callback {
    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    override val kind = EngineKind.MPV
    override var onEvent: (EngineEvent) -> Unit = {}

    private var initialised = false
    private var surfaceView: SurfaceView? = null
    private var started = false           // the first picture of this load has been reached
    private var pos = 0.0; private var dur = 0.0; private var paused = false

    companion object {
        /** True when this device can run libmpv (Android 8+ and the native libraries load). */
        fun isSupported(): Boolean = android.os.Build.VERSION.SDK_INT >= 26 && runCatching { Class.forName("dev.jdtech.mpv.MPVLib"); true }.getOrDefault(false)
    }

    private fun ensureInit() {
        if (initialised) return
        MPVLib.create(appContext)
        MPVLib.setOptionString("vo", "gpu")
        MPVLib.setOptionString("gpu-context", "android")
        MPVLib.setOptionString("opengl-es", "yes")
        MPVLib.setOptionString("volume-max", "150")
        MPVLib.setOptionString("hwdec", "mediacodec,mediacodec-copy")
        MPVLib.setOptionString("hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        MPVLib.setOptionString("ao", "audiotrack,opensles")
        MPVLib.setOptionString("tls-verify", "no")                  // many providers use self-signed https and mpv bundles no certificate list
        MPVLib.setOptionString("network-timeout", "20")
        MPVLib.setOptionString("cache", "yes")
        MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
        MPVLib.setOptionString("keep-open", "no")
        // IPTV servers drop connections: reconnect by itself, and play on a frame drop instead of stalling.
        MPVLib.setOptionString("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5")
        MPVLib.setOptionString("framedrop", "vo")
        MPVLib.setOptionString("video-sync", "audio")
        MPVLib.setOptionString("vd-lavc-threads", "4")
        MPVLib.setOptionString("sub-auto", "fuzzy")
        MPVLib.init()
        MPVLib.observeProperty("time-pos", MPVLib.MPV_FORMAT_DOUBLE)
        MPVLib.observeProperty("duration", MPVLib.MPV_FORMAT_DOUBLE)
        MPVLib.observeProperty("pause", MPVLib.MPV_FORMAT_FLAG)
        MPVLib.observeProperty("paused-for-cache", MPVLib.MPV_FORMAT_FLAG)
        MPVLib.observeProperty("track-list/count", MPVLib.MPV_FORMAT_INT64)
        MPVLib.addObserver(this)
        initialised = true
    }

    override fun view(context: Context): View {
        surfaceView?.let { return it }
        val v = SurfaceView(context).apply { keepScreenOn = true; holder.addCallback(this@MpvEngine) }
        surfaceView = v
        return v
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        ensureInit()
        MPVLib.attachSurface(holder.surface)
        MPVLib.setOptionString("force-window", "yes")
        MPVLib.setPropertyString("vo", "gpu")
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { if (initialised) MPVLib.setPropertyString("android-surface-size", "${width}x$height") }
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (!initialised) return
        MPVLib.setPropertyString("vo", "null")
        MPVLib.setOptionString("force-window", "no")
        MPVLib.detachSurface()
    }

    override fun load(request: EngineRequest) {
        ensureInit()
        started = false; pos = 0.0; dur = 0.0
        // A live stream starts faster with a short probe; a movie is probed fully so its tracks are right.
        MPVLib.setPropertyString("demuxer-lavf-analyzeduration", if (request.live) "1" else "5")
        MPVLib.setPropertyString("demuxer-lavf-probesize", if (request.live) "500000" else "5000000")
        MPVLib.setPropertyString("cache-pause-wait", if (request.live) "1" else "2")
        MPVLib.setPropertyString("cache-secs", request.buffering.mpvCacheSecs.toString())
        MPVLib.setPropertyString("demuxer-readahead-secs", request.buffering.mpvCacheSecs.toString())
        MPVLib.setPropertyString("user-agent", request.headers["User-Agent"] ?: "StreamSetu/0.1 (Android TV)")
        val extra = request.headers.filterKeys { it != "User-Agent" }.map { "${it.key}: ${it.value}".replace(",", "%2C") }
        MPVLib.setPropertyString("http-header-fields", extra.joinToString(","))
        val st = request.options.subtitles
        applySubtitleStyle(st)
        MPVLib.setPropertyString("http-proxy", request.options.httpProxy ?: "")
        MPVLib.setPropertyString("pause", "no")
        if (request.startMs > 5_000) MPVLib.command(arrayOf("loadfile", request.url, "replace", "-1", "start=${request.startMs / 1000}"))
        else MPVLib.command(arrayOf("loadfile", request.url, "replace"))
        onEvent(EngineEvent.Buffering)
    }

    override fun setSpeed(speed: Float) { if (initialised) MPVLib.setPropertyDouble("speed", speed.toDouble()) }
    override fun setAspect(mode: AspectMode) {
        if (!initialised) return
        when (mode) {
            AspectMode.FIT -> { MPVLib.setPropertyDouble("panscan", 0.0); MPVLib.setPropertyDouble("video-zoom", 0.0) }
            AspectMode.FILL -> { MPVLib.setPropertyDouble("panscan", 1.0); MPVLib.setPropertyDouble("video-zoom", 0.0) }
            AspectMode.ZOOM -> { MPVLib.setPropertyDouble("panscan", 1.0); MPVLib.setPropertyDouble("video-zoom", 0.2) }
        }
    }

    override val supportsPictureTuning get() = true

    /** Picture controls, loudness and hardware decoding, live. */
    override fun applyTuning(t: PlayerTuning): Boolean {
        if (!initialised) return false
        MPVLib.setPropertyInt("brightness", t.brightness); MPVLib.setPropertyInt("contrast", t.contrast)
        MPVLib.setPropertyInt("saturation", t.saturation); MPVLib.setPropertyInt("gamma", t.gamma)
        MPVLib.setPropertyString("deinterlace", if (t.deinterlace) "yes" else "no")
        MPVLib.setPropertyString("hwdec", if (t.softwareDecoding) "no" else "mediacodec,mediacodec-copy")
        MPVLib.setPropertyInt("volume", t.boostPercent.coerceIn(100, 150))
        MPVLib.setPropertyString("af", if (t.normalizeLoudness) "loudnorm" else "")
        return true
    }

    override fun chapters(): List<Chapter> {
        if (!initialised) return emptyList()
        val n = MPVLib.getPropertyInt("chapter-list/count") ?: return emptyList()
        return (0 until n).map { i ->
            Chapter(MPVLib.getPropertyString("chapter-list/$i/title")?.takeIf { it.isNotBlank() } ?: "Chapter ${i + 1}", ((MPVLib.getPropertyDouble("chapter-list/$i/time") ?: 0.0) * 1000).toLong())
        }
    }

    override fun applySubtitleStyle(style: SubtitleStyle) {
        if (!initialised) return
        MPVLib.setPropertyString("sub-font-size", (55 * style.scale).toInt().toString())
        MPVLib.setPropertyString("sub-border-size", if (style.outline) "3" else "0")
        MPVLib.setPropertyString("sub-back-color", if (style.darkBackground) "#B3000000" else "#00000000")
        MPVLib.setPropertyString("sub-color", "#%06X".format(style.color and 0xFFFFFF))
        MPVLib.setPropertyInt("sub-pos", (100 - style.raise * 6).coerceIn(50, 100))
    }

    override fun setVideoEnabled(enabled: Boolean) { if (initialised) MPVLib.setPropertyString("vid", if (enabled) "auto" else "no") }
    override fun addSubtitle(address: String, label: String): Boolean {
        if (!initialised) return false
        MPVLib.command(arrayOf("sub-add", address.removePrefix("file://"), "select", label)); return true
    }
    override fun setSubtitleDelay(ms: Long): Boolean { if (!initialised) return false; MPVLib.setPropertyDouble("sub-delay", ms / 1000.0); return true }
    override fun setAudioDelay(ms: Long): Boolean { if (!initialised) return false; MPVLib.setPropertyDouble("audio-delay", ms / 1000.0); return true }

    override fun play() { if (initialised) MPVLib.setPropertyBoolean("pause", false) }
    override fun pause() { if (initialised) MPVLib.setPropertyBoolean("pause", true) }
    override fun seekTo(positionMs: Long) { if (initialised) MPVLib.command(arrayOf("seek", (positionMs / 1000.0).toString(), "absolute")) }
    override fun stop() { if (initialised) MPVLib.command(arrayOf("stop")) }
    override fun release() {
        if (!initialised) return
        MPVLib.removeObserver(this)
        MPVLib.destroy()
        initialised = false
    }
    override val positionMs get() = (pos * 1000).toLong()
    override val durationMs get() = (dur * 1000).toLong()
    override val isPlaying get() = started && !paused

    // ---- events from libmpv (its own thread) -----------------------------------------------------------------------------------------

    override fun eventProperty(property: String) {}
    override fun eventProperty(property: String, value: Long) { if (property == "track-list/count") main.post { onEvent(EngineEvent.TracksChanged) } }
    override fun eventProperty(property: String, value: Double) {
        when (property) { "time-pos" -> pos = value; "duration" -> dur = value }
    }
    override fun eventProperty(property: String, value: Boolean) {
        when (property) {
            "pause" -> { paused = value; if (started) main.post { onEvent(EngineEvent.Ready(!value)) } }
            "paused-for-cache" -> if (started) main.post { onEvent(if (value) EngineEvent.Buffering else EngineEvent.Ready(!paused)) }
        }
    }
    override fun eventProperty(property: String, value: String) {}

    override fun event(eventId: Int) {
        when (eventId) {
            MPVLib.MPV_EVENT_FILE_LOADED, MPVLib.MPV_EVENT_PLAYBACK_RESTART -> {
                if (!started) { started = true; main.post { onEvent(EngineEvent.Ready(!paused)); onEvent(EngineEvent.TracksChanged) } }
            }
            MPVLib.MPV_EVENT_END_FILE -> main.post {
                if (!started) onEvent(EngineEvent.Error(PlaybackError(ErrorKind.FORMAT, "MPV could not open this stream")))
                else if (dur > 0 && pos >= dur - 2) onEvent(EngineEvent.Ended)
            }
        }
    }

    // ---- tracks ----------------------------------------------------------------------------------------------------------------------

    private fun tracks(type: String): List<TrackOption> {
        if (!initialised) return emptyList()
        val n = MPVLib.getPropertyInt("track-list/count") ?: return emptyList()
        return (0 until n).mapNotNull { i ->
            if (MPVLib.getPropertyString("track-list/$i/type") != type) return@mapNotNull null
            val id = MPVLib.getPropertyInt("track-list/$i/id") ?: return@mapNotNull null
            val lang = MPVLib.getPropertyString("track-list/$i/lang")
            val title = MPVLib.getPropertyString("track-list/$i/title")
            val label = title ?: lang?.let { runCatching { java.util.Locale(it).displayLanguage }.getOrNull() } ?: "Track $id"
            TrackOption(id.toString(), label, lang, MPVLib.getPropertyBoolean("track-list/$i/selected") == true)
        }
    }

    override fun audioTracks() = tracks("audio")
    override fun subtitleTracks() = tracks("sub")
    override fun setRecording(path: String?): Boolean = runCatching { MPVLib.setPropertyString("stream-record", path.orEmpty()); true }.getOrDefault(false)

    override fun frameRate(): Float = runCatching { MPVLib.getPropertyString("container-fps") }.getOrNull()?.toFloatOrNull() ?: 0f

    override fun diagnostics(): Map<String, String> {
        if (!initialised) return emptyMap()
        fun prop(n: String) = runCatching { MPVLib.getPropertyString(n) }.getOrNull().orEmpty()
        return linkedMapOf(
            "Video" to listOf("${prop("video-params/w")}×${prop("video-params/h")}", prop("video-format"), prop("container-fps").toDoubleOrNull()?.let { "%.0f fps".format(it) }.orEmpty()).filter { it.isNotBlank() && it != "×" }.joinToString(" · ").ifBlank { "none" },
            "Audio" to listOf(prop("audio-codec-name"), prop("audio-params/channel-count").takeIf { it.isNotBlank() }?.let { "$it ch" }.orEmpty()).filter { it.isNotBlank() }.joinToString(" · ").ifBlank { "none" },
            "Video bitrate" to (prop("video-bitrate").toDoubleOrNull()?.takeIf { it > 0 }?.let { "${(it / 1000).toInt()} kbps" } ?: "unknown"),
            "Decoder" to prop("hwdec-current").ifBlank { "software" },
            "Buffered ahead" to (prop("demuxer-cache-duration").toDoubleOrNull()?.let { "%.0f s".format(it) } ?: "unknown"),
            "Dropped frames" to prop("vo-drop-frame-count").ifBlank { "0" },
        )
    }

    override fun selectAudio(id: String?) { if (initialised) MPVLib.setPropertyString("aid", id ?: "no") }
    override fun selectSubtitle(id: String?) { if (initialised) MPVLib.setPropertyString("sid", id ?: "no") }

    override fun streamInfo(): String {
        if (!initialised) return ""
        val w = MPVLib.getPropertyInt("video-params/w"); val h = MPVLib.getPropertyInt("video-params/h")
        return listOfNotNull(if (w != null && h != null) "${w}×$h" else null, MPVLib.getPropertyString("video-format"), MPVLib.getPropertyString("audio-codec-name"),
            MPVLib.getPropertyString("hwdec-current")?.takeIf { it != "no" }?.let { "hw: $it" }).joinToString(" · ")
    }
}
