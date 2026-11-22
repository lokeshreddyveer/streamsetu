package app.streamsetu.tv

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Pictures come from many providers over many kinds of links. A request that fails for a moment (a dropped connection, a busy server, a 5xx) is tried again after a short wait that grows
 * (0.4 s, then 1.2 s), at most [attempts] times in all, so a poster is not left blank for the whole session because of one bad second. An answer that will not change (a 4xx) is not repeated,
 * and a cancelled request (the list scrolled on) stops at once. After the last try the failure is passed on and the card shows its designed fallback tile.
 */
class ImageRetry(private val attempts: Int = 3, private val waitMs: LongArray = longArrayOf(400, 1200), private val sleep: (Long) -> Unit = { Thread.sleep(it) }) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        var last: IOException? = null
        for (i in 0 until attempts) {
            if (chain.call().isCanceled()) throw IOException("Canceled")
            try {
                val r = chain.proceed(chain.request())
                if (r.code < 500 || i == attempts - 1) return r
                r.close()
                last = IOException("HTTP ${r.code}")
            } catch (e: IOException) {
                if (chain.call().isCanceled() || i == attempts - 1) throw e
                last = e
            }
            sleep(waitMs[minOf(i, waitMs.size - 1)])
        }
        throw last ?: IOException("failed")
    }
}
