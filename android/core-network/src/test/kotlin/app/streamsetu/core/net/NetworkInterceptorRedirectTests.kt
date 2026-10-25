package app.streamsetu.core.net

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/** The picture loader adds a Plex token in a network interceptor, once per hop (ArtworkAuth). This checks what OkHttp does with that header when the server redirects elsewhere. */
class NetworkInterceptorRedirectTests {
    private lateinit var plex: MockWebServer
    private lateinit var other: MockWebServer

    @Before fun start() { plex = MockWebServer().also { it.start() }; other = MockWebServer().also { it.start() } }
    @After fun stop() { plex.shutdown(); other.shutdown() }

    private fun client() = OkHttpClient.Builder().addNetworkInterceptor { chain ->
        val r = chain.request()
        val token = if (r.url.port == plex.port) "secret" else null
        chain.proceed(if (token != null && r.header("X-Plex-Token") == null) r.newBuilder().header("X-Plex-Token", token).build() else r)
    }.build()

    @Test fun aTokenAddedByANetworkInterceptorDoesNotFollowARedirectToAnotherServer() {
        plex.enqueue(MockResponse().setResponseCode(302).setHeader("Location", other.url("/pic").toString()))
        other.enqueue(MockResponse().setBody("x"))
        client().newCall(Request.Builder().url(plex.url("/photo")).build()).execute().close()
        assertEquals("secret", plex.takeRequest().getHeader("X-Plex-Token"))
        assertNull(other.takeRequest().getHeader("X-Plex-Token"))
    }
}
