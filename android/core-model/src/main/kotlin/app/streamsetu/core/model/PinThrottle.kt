package app.streamsetu.core.model

/**
 * Slows down guessing of a PIN: after a few wrong tries in a row every try is refused for a minute. One per PIN, so each screen that asks for that PIN shares the same count.
 * [read] and [write] keep a small string by name (shared preferences in the app, a map in tests).
 */
class PinThrottle(
    private val name: String,
    private val read: (String) -> String?,
    private val write: (String, String?) -> Unit,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    sealed interface Outcome {
        data object Right : Outcome
        data class Wrong(val attemptsLeft: Int) : Outcome
        data class Locked(val retryInMs: Long) : Outcome
    }

    private val failuresKey get() = "pinthrottle.failures.$name"
    private val untilKey get() = "pinthrottle.until.$name"

    /** Milliseconds until a try is allowed again, or null when one is allowed now. */
    fun lockedForMs(): Long? = read(untilKey)?.toLongOrNull()?.let { it - now() }?.takeIf { it > 0 }

    /** Checks a try. [matches] is only called when a try is allowed. */
    fun attempt(matches: () -> Boolean): Outcome {
        lockedForMs()?.let { return Outcome.Locked(it) }
        if (matches()) { write(failuresKey, null); write(untilKey, null); return Outcome.Right }
        val failures = (read(failuresKey)?.toIntOrNull() ?: 0) + 1
        if (failures >= MAX_ATTEMPTS) {
            write(failuresKey, null); write(untilKey, (now() + LOCKOUT_MS).toString())
            return Outcome.Wrong(0)
        }
        write(failuresKey, failures.toString())
        return Outcome.Wrong(MAX_ATTEMPTS - failures)
    }

    companion object {
        const val MAX_ATTEMPTS = 5
        const val LOCKOUT_MS = 60_000L
    }
}
