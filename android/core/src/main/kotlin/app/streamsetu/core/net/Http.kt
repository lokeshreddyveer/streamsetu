package app.streamsetu.core.net

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/** One shared client. IPTV servers are slow to answer the first request, so the timeouts are generous. */
object Http {
    const val USER_AGENT = "StreamSetu/0.1 (Android TV)"

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true).followSslRedirects(true)
            .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("User-Agent", USER_AGENT).build()) }
            .build()
    }

    fun get(url: String, block: (okhttp3.Response) -> Unit) {
        client.newCall(Request.Builder().url(url).build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("The server answered ${r.code}")
            block(r)
        }
    }

    fun text(url: String): String {
        var out = ""
        get(url) { out = it.body?.string().orEmpty() }
        return out
    }
}
