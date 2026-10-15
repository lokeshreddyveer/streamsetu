package app.streamsetu.tv

/** Which physical press opened the menu that is open now. Every event of one press (the first down, the repeats, the release) carries the same down time. */
object OpeningPress {
    @Volatile var downTime = 0L
}

/**
 * Tells a click of OK from holding it. Seen by the activity before any screen can take the key: after [holdMs] the thing the remote is on gets its long press, and every key event
 * that belongs to that press (the repeats while it is held, and the release) is swallowed, so a hold is never also a click. A press that ends sooner passes through as an ordinary click.
 * What the long press opens does not depend on the key any more: it stays until it is closed.
 */
class HoldToSelect(
    private val hasHandler: () -> Boolean,
    private val schedule: (delayMs: Long, run: () -> Unit) -> Unit,
    private val cancel: () -> Unit,
    private val fire: () -> Unit,
    private val holdMs: Long = 520,
) {
    private var fired = false
    private var pressDownTime = 0L
    private val timer = Runnable { fired = true; OpeningPress.downTime = pressDownTime; fire() }

    /** True when the activity must consume this event instead of passing it on. */
    fun onSelect(down: Boolean, repeatCount: Int, downTime: Long = 0L): Boolean {
        if (down) {
            if (repeatCount == 0) { fired = false; pressDownTime = downTime; cancel(); if (hasHandler()) schedule(holdMs, timer::run) }
            return fired
        }
        cancel()
        if (fired) { fired = false; return true }
        return false
    }
}
