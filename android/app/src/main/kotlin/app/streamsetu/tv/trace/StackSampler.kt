package app.streamsetu.tv.trace

import android.util.Log

/**
 * Where the CPU time of the app's threads goes, from sampling their stacks: every [PERIOD_MS] each thread that is running is counted under its kind of thread (main, a worker pool, the
 * database) and the first app frame on its stack. A summary of the busiest places is written to the log (`adb logcat -s Sampler`) every few seconds. For test builds only: it is off unless the
 * device has been told `setprop log.tag.SSSAMPLE VERBOSE`, and sampling slows the app a little, so measure speed without it and use it to find out why.
 */
class StackProfile {
    private val counts = HashMap<String, Int>()
    private var samples = 0

    fun add(kind: String, appFrame: String, topFrame: String) {
        counts["$kind | $appFrame | in $topFrame"] = (counts["$kind | $appFrame | in $topFrame"] ?: 0) + 1
    }

    fun tick() { samples++ }

    /** The [n] places the most samples landed in, as "percent of samples  kind | app frame | in top frame", and a fresh start. */
    fun report(n: Int = 8): List<String> {
        val lines = counts.entries.sortedByDescending { it.value }.take(n).map { "%3d%%  %s".format(it.value * 100 / maxOf(samples, 1), it.key) }
        counts.clear(); samples = 0
        return lines
    }
}

object StackSampler {
    private const val PERIOD_MS = 40L
    private const val REPORT_EVERY_MS = 5_000L
    @Volatile private var running = false

    fun startIfSwitchedOn() {
        if (running || !Log.isLoggable("SSSAMPLE", Log.VERBOSE)) return
        running = true
        Thread({
            val profile = StackProfile(); var last = System.currentTimeMillis()
            val me = Thread.currentThread()
            while (true) {
                try { Thread.sleep(PERIOD_MS) } catch (e: InterruptedException) { return@Thread }
                profile.tick()
                for ((t, st) in Thread.getAllStackTraces()) {
                    if (t === me || t.state != Thread.State.RUNNABLE || st.isEmpty()) continue
                    if (isWaiting(st[0])) continue                 // parked in a system call (waiting for a message, a socket, a lock): not using the CPU
                    val app = st.firstOrNull { it.className.startsWith("app.streamsetu") }
                    val top = st[0]
                    profile.add(kindOf(t.name), app?.let { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" } ?: "(no app frame)", "${top.className.substringAfterLast('.')}.${top.methodName}")
                }
                val now = System.currentTimeMillis()
                if (now - last >= REPORT_EVERY_MS) { last = now; profile.report().forEach { Log.i("Sampler", it) }; Log.i("Sampler", "----") }
            }
        }, "sampler").apply { isDaemon = true; start() }
    }

    /** Java calls a thread that sits in a native wait "running"; these frames are such waits. */
    internal fun isWaiting(top: StackTraceElement): Boolean = top.methodName in WAITS || top.className.endsWith("Linux") && top.methodName == "poll"

    private val WAITS = setOf("nativePollOnce", "socketRead0", "poll", "epollWait", "park", "parkNanos", "wait", "sleep", "nativeWait", "accept0", "nativeAwait", "futexWait")

    internal fun kindOf(name: String) = when {
        name == "main" -> "main"
        name.startsWith("RenderThread") -> "render"
        name.startsWith("arch_disk_io") -> "database"
        name.startsWith("DefaultDispatcher") -> "worker"
        else -> name.replace(Regex("[-_ #]?\\d+$"), "").take(24)
    }
}
