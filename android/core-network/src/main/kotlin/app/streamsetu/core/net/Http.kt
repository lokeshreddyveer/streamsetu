package app.streamsetu.core.net

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/** One shared client. IPTV servers are slow to answer the first request, so the timeouts are generous. */
object Http {
    const val USER_AGENT = "StreamSetu/0.1 (Android TV)"

    /** The proxy every request goes through, chosen in Settings; null means none. Read for each connection, so a change applies at once. */
    @Volatile var proxy: java.net.Proxy? = null

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .proxySelector(object : java.net.ProxySelector() {
                override fun select(uri: java.net.URI?): List<java.net.Proxy> {
                    val p = proxy ?: return listOf(java.net.Proxy.NO_PROXY)
                    // Addresses on the local network (a tuner, a NAS, a media server) are never sent through the proxy.
                    return if (isLocal(uri?.host.orEmpty())) listOf(java.net.Proxy.NO_PROXY) else listOf(p)
                }
                override fun connectFailed(uri: java.net.URI?, sa: java.net.SocketAddress?, ioe: IOException?) {}
            })
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true).followSslRedirects(true)
            .addInterceptor { chain -> chain.request().let { r -> chain.proceed(if (r.header("User-Agent") == null) r.newBuilder().header("User-Agent", USER_AGENT).build() else r) } }   // the app's own name only when the request names none
            .build()
    }

    private val localAddress = Regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2\\d|3[01])\\.|127\\.|169\\.254\\.)")

    /** True for a name or address that is on this device's own network. */
    fun isLocal(host: String): Boolean {
        val h = host.lowercase()
        return h.isNotEmpty() && (h == "localhost" || h.endsWith(".local") || localAddress.containsMatchIn(h) || ('.' !in h && ':' !in h))
    }

    /** Builds a proxy from the Settings values: kind HTTP or SOCKS, a host and a port. Null when it is off or incomplete. */
    fun makeProxy(kind: String, host: String, port: Int): java.net.Proxy? {
        if (kind == "NONE" || host.isBlank() || port !in 1..65535) return null
        return java.net.Proxy(if (kind == "SOCKS") java.net.Proxy.Type.SOCKS else java.net.Proxy.Type.HTTP, java.net.InetSocketAddress.createUnresolved(host.trim(), port))
    }

    fun basic(user: String, pass: String): String = "Basic " + java.util.Base64.getEncoder().encodeToString("$user:$pass".toByteArray())

    fun get(url: String, userAgent: String? = null, headers: Map<String, String> = emptyMap(), block: (okhttp3.Response) -> Unit) {
        client.newCall(Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) }; if (!userAgent.isNullOrBlank()) header("User-Agent", userAgent) }.build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("The server answered ${r.code}")
            block(r)
        }
    }

    fun text(url: String, userAgent: String? = null, headers: Map<String, String> = emptyMap()): String {
        var out = ""
        get(url, userAgent, headers) { out = it.body?.string().orEmpty() }
        return out
    }
}
