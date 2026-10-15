package app.streamsetu.core.net

import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class RedirectSecretsTests {
    private lateinit var first: MockWebServer
    private lateinit var other: MockWebServer

    @Before fun start() { first = MockWebServer().also { it.start() }; other = MockWebServer().also { it.start() } }
    @After fun stop() { first.shutdown(); other.shutdown() }

    private fun call(url: okhttp3.HttpUrl) = Http.client.newCall(Request.Builder().url(url).header("X-Plex-Token", "secret").header("X-Custom-Api-Key", "k").header("X-Harmless", "ok").build()).execute().close()

    @Test fun aRedirectToAnotherServerLeavesTheTokensBehind() {
        first.enqueue(MockResponse().setResponseCode(302).setHeader("Location", other.url("/file").toString()))
        other.enqueue(MockResponse().setBody("x"))
        call(first.url("/start"))
        val seen = other.takeRequest()
        assertNull(seen.getHeader("X-Plex-Token")); assertNull(seen.getHeader("X-Custom-Api-Key"))
        assertEquals("ok", seen.getHeader("X-Harmless"))
    }

    @Test fun aRedirectWithinTheSameServerKeepsThem() {
        first.enqueue(MockResponse().setResponseCode(302).setHeader("Location", first.url("/next").toString()))
        first.enqueue(MockResponse().setBody("x"))
        call(first.url("/start"))
        first.takeRequest()
        assertEquals("secret", first.takeRequest().getHeader("X-Plex-Token"))
    }
}
