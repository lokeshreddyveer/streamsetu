package app.streamsetu.core.data.repo

import app.streamsetu.core.net.HttpStatusException

/** Why a TMDB request did not work, in words that are true: "offline" is said only when there is no connection at all. */
object TmdbProblem {
    enum class Kind { OFFLINE, NOT_ANSWERING, KEY_REJECTED, BUILT_IN_REJECTED, RATE_LIMITED }

    /** [online]: the device has a connection. [builtIn]: the key in use is the app's own. */
    fun kind(e: Throwable, online: Boolean, builtIn: Boolean): Kind = when {
        !online -> Kind.OFFLINE
        e is HttpStatusException && (e.code == 401 || e.code == 403) -> if (builtIn) Kind.BUILT_IN_REJECTED else Kind.KEY_REJECTED
        e is HttpStatusException && e.code == 429 -> Kind.RATE_LIMITED
        else -> Kind.NOT_ANSWERING
    }

    fun message(k: Kind): String = when (k) {
        Kind.OFFLINE -> "You are offline"
        Kind.NOT_ANSWERING -> "The details service did not answer. Try again."
        Kind.KEY_REJECTED -> "TMDB did not accept your key. Check it in Settings."
        Kind.BUILT_IN_REJECTED -> "The built-in key is not working; add your own free key to keep artwork."
        Kind.RATE_LIMITED -> "TMDB is busy right now. Try again in a moment."
    }

    fun message(e: Throwable, online: Boolean, builtIn: Boolean) = message(kind(e, online, builtIn))
}
