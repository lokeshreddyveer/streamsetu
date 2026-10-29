package app.streamsetu.tv.trace

import android.util.Log

/**
 * A log of key presses, focus moves and the navigation flags, for the automated tests only. It is off: nothing is written and nothing extra is measured unless the device has been told
 * `setprop log.tag.SSTRACE VERBOSE`, which is read when the app comes to the front. The tests read this log instead of dumping the screen after every press, which is what made them slow.
 */
object SSTrace {
    @Volatile var on = false
        private set
    fun refresh() { on = Log.isLoggable("SSTRACE", Log.VERBOSE) }
    inline fun v(msg: () -> String) { if (on) Log.v("SSTRACE", msg()) }
}
