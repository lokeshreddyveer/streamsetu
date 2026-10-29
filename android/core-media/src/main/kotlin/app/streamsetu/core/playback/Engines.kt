package app.streamsetu.core.playback

import android.content.Context
import android.view.View

enum class EngineKind(val label: String) { EXOPLAYER("ExoPlayer"), MPV("MPV") }

enum class StreamContainer { HLS, MP4, MPEG_TS, MKV, AVI, RTSP, DASH, UNKNOWN;
    companion object {
        /** Guessed from the address, the same way the Mac app does. A live Xtream stream with no extension is MPEG-TS. */
        fun of(url: String, live: Boolean): StreamContainer {
            val path = url.substringBefore('?').lowercase()
            return when {
                url.startsWith("rtsp") -> RTSP
                path.endsWith(".m3u8") || ".m3u8" in path -> HLS
                path.endsWith(".mpd") -> DASH
                path.endsWith(".mkv") || path.endsWith(".webm") -> MKV
                path.endsWith(".avi") || path.endsWith(".wmv") || path.endsWith(".flv") || path.endsWith(".divx") -> AVI
                path.endsWith(".mp4") || path.endsWith(".m4v") || path.endsWith(".mov") -> MP4
                path.endsWith(".ts") -> MPEG_TS
                live -> MPEG_TS
                else -> UNKNOWN
            }
        }
    }
}

/** The Mac's `EngineSelector`: Automatic gives ExoPlayer HLS, MP4, DASH and MPEG-TS, and MPV the formats it handles badly (MKV audio, AVI, RTSP). */
object EngineSelector {
    fun select(container: StreamContainer, pref: EnginePreference, available: Set<EngineKind>): EngineKind {
        val wanted = when (pref) {
            EnginePreference.EXOPLAYER -> EngineKind.EXOPLAYER
            EnginePreference.MPV -> EngineKind.MPV
            EnginePreference.AUTOMATIC -> when (container) {
                StreamContainer.MKV, StreamContainer.AVI, StreamContainer.RTSP -> EngineKind.MPV
                else -> EngineKind.EXOPLAYER
            }
        }
        return if (wanted in available) wanted else available.firstOrNull() ?: EngineKind.EXOPLAYER
    }

    fun other(kind: EngineKind, available: Set<EngineKind>): EngineKind? = available.firstOrNull { it != kind }
}

/** How the picture fills the screen (the iPhone app's Fit / Fill, plus Zoom). */
enum class AspectMode(val label: String) { FIT("Fit"), FILL("Fill"), ZOOM("Zoom") }

/** How subtitles are drawn: a size factor, a dark box behind the text, an outline. */
data class SubtitleStyle(val scale: Float = 1f, val darkBackground: Boolean = false, val outline: Boolean = true, val color: Int = 0xFFFFFFFF.toInt(), val raise: Int = 0)

/** Picture, sound and decoding adjustments for the stream playing now. Zero is unchanged; brightness, contrast, saturation and gamma run from -100 to 100. */
data class PlayerTuning(
    val brightness: Int = 0, val contrast: Int = 0, val saturation: Int = 0, val gamma: Int = 0,
    val deinterlace: Boolean = false, val softwareDecoding: Boolean = false,
    /** 100 is the normal volume; above it the sound is boosted. */
    val boostPercent: Int = 100, val normalizeLoudness: Boolean = false,
) {
    val picture get() = brightness != 0 || contrast != 0 || saturation != 0 || gamma != 0 || deinterlace
}

/** One chapter of a movie: its name and where it starts. */
data class Chapter(val title: String, val startMs: Long)

/** Choices that need the player to be built a certain way. */
data class EngineOptions(val decoderFallback: Boolean = true, val passthrough: Boolean = true, val subtitles: SubtitleStyle = SubtitleStyle(), val httpProxy: String? = null, val softwareDecoding: Boolean = false, val allowSelfSigned: Boolean = false)

data class EngineRequest(val url: String, val headers: Map<String, String>, val startMs: Long, val live: Boolean, val buffering: BufferingMode, val options: EngineOptions = EngineOptions())

sealed interface EngineEvent {
    data object Buffering : EngineEvent
    data class Ready(val playing: Boolean) : EngineEvent
    data object Ended : EngineEvent
    data class Error(val error: PlaybackError) : EngineEvent
    data object TracksChanged : EngineEvent
}

/** One way of playing a stream (the Mac's `PlaybackEngine`). The coordinator owns the choice, the retries and the progress; an engine only plays. */
interface PlayerEngine {
    val kind: EngineKind
    /** The picture. The same view is returned each time. */
    fun view(context: Context): View
    fun load(request: EngineRequest)
    fun play()
    fun pause()
    fun seekTo(positionMs: Long)
    fun stop()
    fun release()
    val positionMs: Long
    val durationMs: Long
    val isPlaying: Boolean
    var onEvent: (EngineEvent) -> Unit
    fun audioTracks(): List<TrackOption>
    fun subtitleTracks(): List<TrackOption>
    fun selectAudio(id: String?)
    fun selectSubtitle(id: String?)
    /** The picture size and codecs of the stream playing now, for the stream information pill and chips. */
    fun facts(): StreamFacts
    /** Facts about the stream playing now, for the diagnostics screen (no addresses, no logins). */
    fun diagnostics(): Map<String, String>
    /** The frame rate of the video playing now, or 0 when it is not known yet. */
    fun frameRate(): Float = 0f
    /** Starts (or, with null, stops) writing the stream being played to a file, over the same connection. False when this engine cannot. */
    fun setRecording(path: String?): Boolean = false
    fun setSpeed(speed: Float)
    fun setAspect(mode: AspectMode)
    /** 0 to 1. Used by Multi-View, where one picture at a time has sound. */
    fun setVolume(volume: Float) {}
    /** Off while only the sound is wanted (the app is in the background, or the mini player is showing): the picture stops being decoded. */
    fun setVideoEnabled(enabled: Boolean) {}
    /** Loads a subtitle file or address for the stream playing now. False when this engine cannot. */
    fun addSubtitle(address: String, label: String): Boolean = false
    /** Moves the subtitles later (positive) or earlier (negative). False when this engine cannot. */
    fun setSubtitleDelay(ms: Long): Boolean = false
    /** Moves the sound later (positive) or earlier (negative) against the picture. False when this engine cannot. */
    fun setAudioDelay(ms: Long): Boolean = false
    /** Applies picture and sound adjustments. False when this engine cannot do any of them (picture controls are MPV's). */
    fun applyTuning(t: PlayerTuning): Boolean = false
    /** True when the picture controls (brightness, contrast, saturation, gamma, deinterlace) work in this engine. */
    val supportsPictureTuning: Boolean get() = false
    /** The sizes or bitrates a stream offers (an HLS stream with several variants); empty when there is only one. */
    fun videoQualities(): List<TrackOption> = emptyList()
    /** Picks one of [videoQualities]; null goes back to automatic. */
    fun selectVideo(id: String?) {}
    fun chapters(): List<Chapter> = emptyList()
    /** Changes how subtitles look while they are on screen. */
    fun applySubtitleStyle(style: SubtitleStyle) {}
}

/** Takes a picture of the frame on screen from the player's surface. */
object FrameGrab {
    private fun find(v: View): android.view.View? {
        if (v is android.view.SurfaceView || v is android.view.TextureView) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
        return null
    }

    fun grab(root: View, done: (android.graphics.Bitmap?) -> Unit) {
        when (val v = find(root)) {
            is android.view.TextureView -> done(runCatching { v.bitmap }.getOrNull())
            is android.view.SurfaceView -> {
                if (android.os.Build.VERSION.SDK_INT < 24 || v.width <= 0 || v.height <= 0) { done(null); return }
                val bmp = android.graphics.Bitmap.createBitmap(v.width, v.height, android.graphics.Bitmap.Config.ARGB_8888)
                runCatching { android.view.PixelCopy.request(v, bmp, { code -> done(if (code == android.view.PixelCopy.SUCCESS) bmp else null) }, android.os.Handler(android.os.Looper.getMainLooper())) }.onFailure { done(null) }
            }
            else -> done(null)
        }
    }
}

/** One way the screen can run: its size and how many times a second it draws. */
data class DisplayMode(val id: Int, val width: Int, val height: Int, val fps: Float)

/** Picks the screen mode that shows a video without judder: the same size as now, and a refresh rate that is a whole multiple of the video's frame rate. */
object DisplayModes {
    private fun multiple(refresh: Float, content: Float): Int? {
        for (m in 1..5) if (kotlin.math.abs(refresh - content * m) < 0.2f) return m
        return null
    }

    /** The mode to switch to, or null when the screen already fits (or nothing fits and it is better left alone). */
    fun best(modes: List<DisplayMode>, current: DisplayMode, contentFps: Float): DisplayMode? {
        if (contentFps < 10f) return null
        if (multiple(current.fps, contentFps) != null) return null
        return modes.filter { it.width == current.width && it.height == current.height }
            .mapNotNull { m -> multiple(m.fps, contentFps)?.let { m to it } }
            .minWithOrNull(compareBy({ it.second }, { kotlin.math.abs(it.first.fps - contentFps * it.second) }))?.first        // the fewest repeats of a frame, then the closest rate
    }
}
