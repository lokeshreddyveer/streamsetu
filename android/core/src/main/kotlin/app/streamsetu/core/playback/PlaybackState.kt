package app.streamsetu.core.playback

/** What the person sees. One value, not a bag of flags. */
sealed interface PlaybackState {
    data object Idle : PlaybackState
    data object Resolving : PlaybackState
    data object Buffering : PlaybackState
    data object Playing : PlaybackState
    data object Paused : PlaybackState
    data object Ended : PlaybackState
    /** Waiting a moment before trying again. */
    data class Retrying(val attempt: Int, val inSeconds: Int) : PlaybackState
    data class Failed(val error: PlaybackError) : PlaybackState
}

enum class ErrorKind { NO_NETWORK, SERVER_REFUSED, NOT_FOUND, TIMEOUT, FORMAT, DECODER, UNKNOWN }

data class PlaybackError(val kind: ErrorKind, val message: String, val httpStatus: Int? = null)

data class TrackOption(val id: String, val label: String, val language: String?, val selected: Boolean)
