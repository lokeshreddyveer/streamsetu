package app.streamsetu.core.data

import app.streamsetu.core.model.*
import app.streamsetu.core.net.StalkerClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class StalkerClientTests {
    private lateinit var server: MockWebServer
    private val seen = ArrayList<RecordedRequest>()

    @Before fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen += request
                val q = request.requestUrl.toString()
                return when {
                    "action=handshake" in q -> MockResponse().setBody("""{"js":{"token":"TOK123"}}""")
                    "action=get_profile" in q -> MockResponse().setBody("""{"js":{"id":"1"}}""")
                    "action=get_genres" in q -> MockResponse().setBody("""{"js":[{"id":"1","title":"News"},{"id":"2","title":"Radio"}]}""")
                    "action=get_all_channels" in q -> MockResponse().setBody("""{"js":{"data":[{"id":"10","name":"News One","number":"1","logo":"http://x/l.png","cmd":"ffrt http://localhost/ch/10","tv_genre_id":"1","xmltv_id":"news1"},{"id":"11","name":"Jazz FM","cmd":"ffrt http://localhost/ch/11","tv_genre_id":"2"}]}}""")
                    "action=create_link" in q -> MockResponse().setBody("""{"js":{"cmd":"ffmpeg http://stream.example/live/10.ts?token=abc"}}""")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }
    @After fun stop() = server.shutdown()

    private fun source() = Source("s1", "Portal", SourceType.STALKER, server.url("/stalker_portal/c/").toString(), username = "00:1a:79:aa:bb:cc")

    @Test fun portalAddressBecomesTheLoadEndpoint() {
        val c = StalkerClient()
        assertEquals("http://h/stalker_portal/server/load.php", c.loadUrl("http://h/stalker_portal/c/"))
        assertEquals("http://h/server/load.php", c.loadUrl("h/c"))
        assertEquals("http://h/portal.php/server/load.php", c.loadUrl("http://h/portal.php"))
    }
    @Test fun readsGenresAndChannelsAfterSigningIn() {
        val c = StalkerClient(); val s = source()
        assertEquals(listOf("News", "Radio"), c.genres(s).map { it.title })
        val ch = c.channels(s)
        assertEquals(2, ch.size); assertEquals("News One", ch[0].name); assertEquals(1, ch[0].number); assertEquals("news1", ch[0].epgId); assertNull(ch[1].number)
    }
    @Test fun signsInWithTheMacCookieAndThenUsesTheToken() {
        val c = StalkerClient(); val s = source(); c.channels(s)
        val first = seen.first { "action=handshake" in it.requestUrl.toString() }
        assertTrue(first.getHeader("Cookie")!!.contains("mac=00:1A:79:AA:BB:CC"))
        val channelCall = seen.first { "action=get_all_channels" in it.requestUrl.toString() }
        assertEquals("Bearer TOK123", channelCall.getHeader("Authorization"))
    }
    @Test fun aStreamLinkIsMadeOnDemandAndLosesItsPlayerHint() {
        val url = StalkerClient().link(source(), "ffrt http://localhost/ch/10")
        assertEquals("http://stream.example/live/10.ts?token=abc", url)
    }
    @Test fun aCustomUserAgentIsSent() {
        val s = source().copy(userAgent = "MyPlayer/1.0"); StalkerClient().genres(s)
        assertEquals("MyPlayer/1.0", seen.first().getHeader("User-Agent"))
    }
    @Test fun prefixStrippingKeepsOnlyAddresses() {
        assertEquals("http://a/b", StalkerClient.stripPrefix("ffmpeg http://a/b")); assertEquals("http://a/b", StalkerClient.stripPrefix("http://a/b")); assertNull(StalkerClient.stripPrefix("ffrt localhost/ch/1"))
    }
}
