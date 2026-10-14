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

data class EngineRequest(val url: String, val headers: Map<String, String>, val startMs: Long, val live: Boolean, val buffering: BufferingMode)

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
    /** A line of facts about the stream being played, for the "Show stream information" overlay. */
    fun streamInfo(): String
    fun setSpeed(speed: Float)
    fun setAspect(mode: AspectMode)
}
