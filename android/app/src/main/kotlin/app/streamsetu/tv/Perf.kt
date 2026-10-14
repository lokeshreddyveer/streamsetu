package app.streamsetu.tv

import android.app.ActivityManager
import android.content.Context

/**
 * What this device can afford, judged from what it reports (memory class, low-RAM flag, cores), never from its model name.
 * Low-end devices get a smaller image cache and shorter prefetch; everything still works and looks the same.
 */
object Perf {
    @Volatile private var cached: Boolean? = null
    fun lowEnd(context: Context): Boolean = cached ?: run {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        (am.isLowRamDevice || am.memoryClass <= 192 || Runtime.getRuntime().availableProcessors() <= 4).also { cached = it }
    }
    /** How many posters ahead of the visible ones are fetched. */
    fun prefetchAhead(context: Context) = if (lowEnd(context)) 6 else 14
}
