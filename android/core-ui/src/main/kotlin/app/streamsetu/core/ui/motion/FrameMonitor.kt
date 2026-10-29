package app.streamsetu.core.ui.motion

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.FrameMetrics
import android.view.Window

/**
 * Counts frames and the ones that took too long (over 20 ms, a missed 60 Hz frame), and writes one line to the log every few seconds:
 * `adb logcat -s Motion`. Used to measure the app on the real Fire TV; off unless switched on.
 */
@android.annotation.TargetApi(24)          // start() and stop() do nothing below Android 7
class FrameMonitor(private val activity: Activity) {
    private var frames = 0; private var slow = 0; private var worstMs = 0.0
    private var windowStart = System.nanoTime()
    private val handler = Handler(Looper.getMainLooper())
    private val listener = Window.OnFrameMetricsAvailableListener { _, m, _ ->
        val ms = m.getMetric(FrameMetrics.TOTAL_DURATION) / 1_000_000.0
        frames++; if (ms > 20.0) slow++; if (ms > worstMs) worstMs = ms
        val now = System.nanoTime()
        if (now - windowStart > 5_000_000_000L) {
            Log.i("Motion", "frames=$frames slow=$slow (${if (frames > 0) slow * 100 / frames else 0}%) worst=${"%.1f".format(worstMs)}ms")
            frames = 0; slow = 0; worstMs = 0.0; windowStart = now
        }
    }
    private var running = false

    fun start() {
        if (running || Build.VERSION.SDK_INT < 24) return
        runCatching { activity.window.addOnFrameMetricsAvailableListener(listener, handler); running = true }
    }

    fun stop() {
        if (!running || Build.VERSION.SDK_INT < 24) return
        runCatching { activity.window.removeOnFrameMetricsAvailableListener(listener) }; running = false
    }
}
