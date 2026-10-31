package app.streamsetu.tv.trace

import android.util.Log
import android.view.KeyEvent

/**
 * Time from a real remote key to the first finished frame that shows its result, one log line per key (`adb logcat -s KeyLatency`). For test builds only: nothing runs unless [enable] is called.
 *
 * It starts at the time the system stamped on the key (before the app saw it) and ends when the first frame that was being drawn at the moment focus moved finishes (the focus callback and
 * the next frame are both on the main thread, so that frame is the one that carries the new ring). A key that moves no focus (opening a dialog, going back) ends at the first frame drawn after it.
 * The picture still has to reach the screen after that frame, which no software on the box can see; the figures are a floor for what the viewer experiences.
 */
class KeyLatencyProbe(private val sink: (String) -> Unit, private val keyName: (Int) -> String = { KeyEvent.keyCodeToString(it).removePrefix("KEYCODE_") }) {
    private class Frame(val intendedNs: Long, val endNs: Long)
    private class Pending(val key: Int, val repeat: Int, val screen: String, val eventNs: Long, val recvNs: Long, val thinned: Int) { var focusNs = 0L }

    private val ring = ArrayDeque<Frame>()
    private var pending: Pending? = null
    private var thinned = 0

    /** A key went down. [eventNs] is when the system stamped it, [recvNs] when the app saw it. */
    fun key(key: Int, repeat: Int, screen: String, eventNs: Long, recvNs: Long) {
        pending?.let { done(it, "none", null) }
        pending = Pending(key, repeat, screen, eventNs, recvNs, thinned); thinned = 0
    }

    /** Reports a key that is still waiting after [ageNs] as one that changed nothing, so the last key of a run is not held back until the next one. */
    fun flush(nowNs: Long, ageNs: Long = FLUSH_NS) { pending?.takeIf { nowNs - it.recvNs >= ageNs && it.focusNs == 0L }?.let { done(it, "none", null) } }

    /** A held direction was thinned out before it reached the screen. */
    fun thinned() { thinned++ }

    /** Focus landed on an element (called from the one modifier every focusable card goes through). */
    fun focus(nowNs: Long) { pending?.takeIf { it.focusNs == 0L }?.focusNs = nowNs }

    /** A frame finished: it started at [intendedNs] and ended at [endNs]. */
    fun frame(intendedNs: Long, endNs: Long) {
        ring.addLast(Frame(intendedNs, endNs)); if (ring.size > 8) ring.removeFirst()
        val p = pending ?: return
        if (p.focusNs > 0) { ring.lastOrNull()?.takeIf { it.endNs >= p.focusNs }?.let { done(p, "focus", it); pending = null } }
        else if (endNs - p.recvNs >= RENDER_WAIT_NS) { done(p, "render", ring.firstOrNull { it.endNs >= p.recvNs }); pending = null }
    }

    private fun done(p: Pending, kind: String, f: Frame?) {
        if (pending === p) pending = null
        fun ms(ns: Long) = "%.1f".format(ns / 1_000_000.0)
        val total = f?.let { ms(it.endNs - p.eventNs) } ?: "-"
        val frameMs = f?.let { ms(it.endNs - it.intendedNs) } ?: "-"
        val toFocus = if (p.focusNs > 0) ms(p.focusNs - p.recvNs) else "-"
        sink("screen=${p.screen} key=${keyName(p.key)} rep=${p.repeat} queue=${ms(p.recvNs - p.eventNs)} focus=$toFocus frame=$frameMs total=$total kind=$kind thinned=${p.thinned}")
    }

    private companion object { const val RENDER_WAIT_NS = 100_000_000L; const val FLUSH_NS = 300_000_000L }
}

object KeyLatency {
    @Volatile var on = false
        private set
    private var screen: () -> String = { "?" }
    private val probe = KeyLatencyProbe(sink = { Log.i("KeyLatency", it) })

    fun enable(screenName: () -> String) { screen = screenName; on = true }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val flushLater = Runnable { probe.flush(System.nanoTime()) }

    fun key(e: KeyEvent) {
        if (!on) return
        probe.key(e.keyCode, e.repeatCount, screen(), e.eventTime * 1_000_000L, System.nanoTime())
        main.removeCallbacks(flushLater); main.postDelayed(flushLater, 320)
    }
    fun thinned() { if (on) probe.thinned() }
    fun focus() { if (on) probe.focus(System.nanoTime()) }
    fun frame(intendedNs: Long, endNs: Long) { if (on) probe.frame(intendedNs, endNs) }
}
