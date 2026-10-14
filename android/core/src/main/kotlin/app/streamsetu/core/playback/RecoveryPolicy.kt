package app.streamsetu.core.playback

/**
 * Decides what happens after a stream fails: try again (and how soon) or give up with a plain message.
 * Pure logic, so it is tested without a player. Live streams are tried more often than movies, because a channel usually comes back.
 */
class RecoveryPolicy(private val maxLiveAttempts: Int = 6, private val maxVodAttempts: Int = 3) {
    sealed interface Decision {
        data class Retry(val attempt: Int, val delayMs: Long) : Decision
        data class GiveUp(val error: PlaybackError) : Decision
    }

    fun decide(error: PlaybackError, attemptsSoFar: Int, isLive: Boolean, online: Boolean): Decision {
        if (!online) return Decision.GiveUp(PlaybackError(ErrorKind.NO_NETWORK, "No internet connection. Playback resumes when it returns."))
        val limit = if (isLive) maxLiveAttempts else maxVodAttempts
        val retryable = when (error.kind) {
            ErrorKind.NOT_FOUND, ErrorKind.FORMAT -> false
            ErrorKind.SERVER_REFUSED -> attemptsSoFar < 2            // a refusal is usually a one-connection limit: wait, try twice, then explain
            else -> true
        }
        if (!retryable || attemptsSoFar >= limit) return Decision.GiveUp(explain(error))
        return Decision.Retry(attemptsSoFar + 1, backoffMs(attemptsSoFar + 1, error.kind))
    }

    fun backoffMs(attempt: Int, kind: ErrorKind): Long {
        val base = if (kind == ErrorKind.SERVER_REFUSED) 4_000L else 1_000L
        return (base * (1L shl (attempt - 1).coerceAtMost(4))).coerceAtMost(15_000L)
    }

    private fun explain(e: PlaybackError): PlaybackError = when (e.kind) {
        ErrorKind.SERVER_REFUSED -> PlaybackError(e.kind, "The provider refused the stream. Another device may be using the same account.", e.httpStatus)
        ErrorKind.NOT_FOUND -> PlaybackError(e.kind, "The provider does not have this stream any more.", e.httpStatus)
        ErrorKind.TIMEOUT -> PlaybackError(e.kind, "The provider did not answer in time.", e.httpStatus)
        ErrorKind.FORMAT -> PlaybackError(e.kind, "This video format is not supported on this device.", e.httpStatus)
        ErrorKind.NO_NETWORK -> e
        else -> PlaybackError(e.kind, e.message.ifBlank { "This stream could not be played." }, e.httpStatus)
    }
}
