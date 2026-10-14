package app.streamsetu.core.net

import okhttp3.Request
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/** How a channel answered when asked for its first few kilobytes. */
sealed interface Health {
    data class Ok(val ms: Int) : Health
    /** Answered, but only after several seconds. */
    data class Slow(val ms: Int) : Health
    /** Sent nothing in time. Not proof the channel is gone: some providers take long to start a stream, or refuse a second connection while one is open. Never counted as dead. */
    data object Silent : Health
    /** A definite failure: an error status, an unknown host, a refused connection, or something that is not video. */
    data class Dead(val reason: String) : Health

    val label: String get() = when (this) { is Ok -> "OK · $ms ms"; is Slow -> "Slow · $ms ms"; Silent -> "No answer in time"; is Dead -> reason }
}

object ChannelHealthCheck {
    const val SLOW_AFTER_MS = 3000

    /** The verdict from what came back. Pure, so it is tested without a network. */
    fun classify(code: Int?, firstBytes: ByteArray, ms: Int, error: Throwable?): Health = when {
        error is SocketTimeoutException -> Health.Silent
        error is UnknownHostException -> Health.Dead("Unknown host")
        error is ConnectException -> Health.Dead("Connection refused")
        error != null -> Health.Dead("Connection failed")
        code != null && code >= 400 -> Health.Dead("Server answered $code")
        firstBytes.isEmpty() -> Health.Silent
        looksLikeText(firstBytes) && !firstBytes.decodeToString().trimStart().startsWith("#EXTM3U") -> Health.Dead("Not a video stream")
        ms >= SLOW_AFTER_MS -> Health.Slow(ms)
        else -> Health.Ok(ms)
    }

    private fun looksLikeText(b: ByteArray): Boolean { val t = b.decodeToString(0, minOf(b.size, 64)).trimStart(); return t.startsWith("<") || t.startsWith("{") || t.startsWith("#EXTM3U") }

    /** Asks for the first 4 KB and stops. [timeoutSeconds] is how long to wait for the first bytes. */
    fun check(url: String, headers: Map<String, String> = emptyMap(), userAgent: String? = null, timeoutSeconds: Long = 10): Health {
        val started = System.nanoTime()
        val client = Http.client.newBuilder().callTimeout(timeoutSeconds + 5, TimeUnit.SECONDS).readTimeout(timeoutSeconds, TimeUnit.SECONDS).build()
        val req = Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) }; if (!userAgent.isNullOrBlank()) header("User-Agent", userAgent) }.build()
        return try {
            client.newCall(req).execute().use { r ->
                val buf = ByteArray(4096)
                val n = if (r.isSuccessful) r.body?.byteStream()?.read(buf) ?: -1 else -1
                val ms = ((System.nanoTime() - started) / 1_000_000).toInt()
                classify(r.code, if (n > 0) buf.copyOf(n) else ByteArray(0), ms, null)
            }
        } catch (e: IOException) { classify(null, ByteArray(0), ((System.nanoTime() - started) / 1_000_000).toInt(), e) }
    }
}
