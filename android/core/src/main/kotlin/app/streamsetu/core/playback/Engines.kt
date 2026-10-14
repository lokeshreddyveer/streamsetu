package app.streamsetu.core.playback

import android.content.Context
import android.view.View

/** The Mac's `PlaybackEnginePreference`: Automatic picks per stream; the others force one engine. */
enum class EnginePreference(val label: String) {
    AUTOMATIC("Automatic (recommended)"), EXOPLAYER("Android ExoPlayer"), MPV("MPV");
    companion object { fun from(s: String?) = entries.firstOrNull { it.name == s } ?: AUTOMATIC }
}

enum class EngineKind(val label: String) { EXOPLAYER("ExoPlayer"), MPV("MPV") }

/** The Mac's `BufferingMode`. */
enum class BufferingMode(val label: String, val detail: String, val minMs: Int, val maxMs: Int, val startMs: Int, val rebufferMs: Int, val mpvCacheSecs: Int) {
    AUTOMATIC("Automatic", "A balanced buffer that suits most streams.", 20_000, 60_000, 1_500, 4_000, 20),
    LOW_LATENCY("Low latency (live)", "Stays close to the live edge. Less delay, more risk of stalls.", 5_000, 15_000, 800, 2_000, 4),
    STANDARD("Standard", "A moderate buffer for steady connections.", 15_000, 45_000, 1_500, 4_000, 15),
    LARGE("Large buffer", "Keeps more ahead. Best for slow or unstable providers.", 40_000, 120_000, 2_500, 5_000, 60);
    companion object { fun from(s: String?) = entries.firstOrNull { it.name == s } ?: AUTOMATIC }
}

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
}
