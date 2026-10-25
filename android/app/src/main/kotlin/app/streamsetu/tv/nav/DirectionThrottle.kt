package app.streamsetu.tv.nav

/**
 * Keeps a held direction from queueing faster than the screen can follow. A remote repeats a held button 20 to 30 times a second; a poster grid cannot move focus and redraw
 * that fast on a small stick, so the presses pile up and the cursor keeps running for seconds after the button is let go. Presses of one direction that follow each other closer than
 * [minGapMs], or that waited in the queue longer than [maxAgeMs] (they are already stale), are dropped. A first press, a press after a pause, and a different direction always go through,
 * so ordinary tapping is untouched.
 */
class DirectionThrottle(private val minGapMs: Long = 40, private val maxAgeMs: Long = 120, private val streamGapMs: Long = 150) {
    private var lastKey = 0
    private var lastAt = Long.MIN_VALUE / 2

    /** [eventTime] is when the press happened, [now] is when it reached us (same clock). True = handle it, false = drop it. */
    fun accept(keyCode: Int, eventTime: Long, now: Long): Boolean {
        val stream = keyCode == lastKey && now - lastAt < streamGapMs
        if (stream && (now - lastAt < minGapMs || now - eventTime > maxAgeMs)) return false
        lastKey = keyCode; lastAt = now
        return true
    }

    fun reset() { lastKey = 0; lastAt = Long.MIN_VALUE / 2 }
}
