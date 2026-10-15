package app.streamsetu.core.data

import app.streamsetu.core.model.Source
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.net.*
import app.streamsetu.core.parse.Xtream
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MoreSourcesTests {
    private fun src(type: SourceType, address: String = "http://host", user: String? = "me") = Source("s1", "Test", type, address, username = user)
    private fun objs(json: String): List<JsonObject> = (Xtream.json.parseToJsonElement(json) as JsonArray).map { it as JsonObject }

    @Test fun hdhomerunLineupBecomesChannels() {
        val json = """[{"GuideNumber":"2.1","GuideName":"KCBS","URL":"http://192.168.1.50:5004/auto/v2.1"},{"GuideNumber":"5","GuideName":"Paid","DRM":1,"URL":"http://x/5"},{"GuideNumber":"7","GuideName":"KGO","URL":"http://192.168.1.50:5004/auto/v7"}]"""
        val c = HdHomeRun.parse(src(SourceType.HDHOMERUN), json)
        assertEquals(listOf("KCBS", "KGO"), c.channels.map { it.name })
        assertEquals("http://192.168.1.50:5004/auto/v7", c.channels[1].streamRef)
        assertEquals(7, c.channels[1].number); assertNull(c.channels[0].number)         // "2.1" is not a plain number
        assertEquals("http://192.168.1.50/lineup.json", HdHomeRun.lineupUrl("192.168.1.50/"))
    }

    @Test fun enigma2KeepsOnlyRealChannelsInBouquets() {
        val json = """{"services":[{"servicename":"Favourites","subservices":[{"servicereference":"1:0:19:283D:3FB:1:C00000:0:0:0:","servicename":"Das Erste HD"},{"servicereference":"1:64:0:0:0:0:0:0:0:0:","servicename":"---- marker"},{"servicereference":"1:0:1:1:1:1:1:0:0:0:","servicename":"ZDF"}]},{"servicename":"Empty","subservices":[]}]}"""
        val c = Enigma2.parse(src(SourceType.ENIGMA2), json)
        assertEquals(listOf("Das Erste HD", "ZDF"), c.channels.map { it.name }); assertEquals(1, c.categories.size)
        assertEquals("http://192.168.1.60:8001/1:0:1:1:1:1:1:0:0:0:", Enigma2.streamUrl("http://192.168.1.60", c.channels[1].streamRef))
    }

    @Test fun webDavReplyIsReadAndVideosAreTitled() {
        val xml = """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/Movies/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
            <d:response><d:href>/dav/Movies/Some%20Movie.2019.mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength></d:prop></d:propstat></d:response></d:multistatus>"""
        val rows = WebDavClient().parse(xml)
        assertEquals(listOf("/dav/Movies/", "/dav/Movies/Some Movie.2019.mkv"), rows.map { it.first }); assertTrue(rows[0].second); assertEquals(1234L, rows[1].third)
        assertEquals("Some Movie 2019", VideoFiles.title("Some.Movie.2019.mkv"))
        assertTrue(VideoFiles.isVideo("a.MKV")); assertFalse(VideoFiles.isVideo("a.srt"))
        val (cats, movies) = VideoFiles.catalog(src(SourceType.WEBDAV), listOf(FoundVideo("/dav/Movies/Some Movie.2019.mkv", "Movies", "Some Movie.2019.mkv", 1))) { "dav:${it.path}" }
        assertEquals("Movies", cats.single().name); assertEquals(2019, movies.single().year); assertEquals("dav:/dav/Movies/Some Movie.2019.mkv", movies.single().streamRef)
        assertEquals("http://nas:5005/dav/Movies/Some%20Movie.2019.mkv", WebDavClient().streamUrl(src(SourceType.WEBDAV, "http://nas:5005/dav/"), "dav:/dav/Movies/Some Movie.2019.mkv"))
    }

    @Test fun jellyfinLoginAndCatalogAreMapped() {
        val client = MediaServerClient()
        val session = client.parseSession("""{"AccessToken":"tok","User":{"Id":"u1"}}""")
        assertEquals(MediaServerClient.Session("tok", "u1"), session); assertEquals(session, MediaServerClient.Session.decode(session!!.encoded)); assertNull(client.parseSession("{}"))
        val s = src(SourceType.JELLYFIN)
        val movies = objs("""[{"Id":"m1","Name":"Heat","ProductionYear":1995,"CommunityRating":8.2,"Genres":["Crime"],"Container":"mkv,mp4","ImageTags":{"Primary":"x"},"Overview":"Cops."}]""")
        val shows = objs("""[{"Id":"t1","Name":"The Bear","Genres":[]}]""")
        val c = client.mapCatalog(s, "http://host", movies, shows)
        assertEquals("jf:m1.mkv", c.movies.single().streamRef); assertEquals(1995, c.movies.single().year); assertEquals("http://host/Items/m1/Images/Primary?maxWidth=400", c.movies.single().posterUrl)
        assertEquals("t1", c.series.single().providerId); assertEquals(setOf("Crime", "Series"), c.categories.map { it.name }.toSet())
        assertEquals("http://host/Videos/m1/stream.mkv?static=true&MediaSourceId=m1&DeviceId=streamsetu-s1&api_key=tok", client.streamUrl(s, session, "jf:m1.mkv"))
        assertEquals("http://host/emby", client.base(src(SourceType.EMBY, "host")))
        val eps = client.mapEpisodes(s, "http://host", "s1:sr:t1", objs("""[{"Id":"e1","Name":"System","ParentIndexNumber":1,"IndexNumber":1,"RunTimeTicks":18000000000,"Container":"mp4"}]"""))
        assertEquals(1800, eps.single().durationSec); assertEquals("jf:e1.mp4", eps.single().streamRef)
    }

    @Test fun plexStreamUrlCarriesTheTokenButAStoredPictureAddressDoesNot() {
        val client = PlexClient(); val s = src(SourceType.PLEX, "http://plex:32400", null)
        val movies = objs("""[{"ratingKey":"10","title":"Heat","year":1995,"thumb":"/library/metadata/10/thumb/1","Genre":[{"tag":"Crime"}],"Media":[{"Part":[{"key":"/library/parts/55/1/file.mkv"}]}],"addedAt":100}]""")
        val c = client.mapCatalog(s, "http://plex:32400", "T0K", movies, emptyList())
        assertEquals("plex:/library/parts/55/1/file.mkv", c.movies.single().streamRef); assertEquals(100_000L, c.movies.single().addedAt)
        assertEquals("http://plex:32400/library/metadata/10/thumb/1", c.movies.single().posterUrl)        // no token in a stored address; the image loader adds it as a header
        assertEquals("http://plex:32400/library/parts/55/1/file.mkv?X-Plex-Token=T0K", client.streamUrl(s, "T0K", "plex:/library/parts/55/1/file.mkv"))
        assertTrue(client.mapCatalog(s, "http://plex:32400", "T", objs("""[{"ratingKey":"11","title":"No file"}]"""), emptyList()).movies.isEmpty())    // nothing to play
    }

    @Test fun headersAndProxyHelpers() {
        assertEquals(mapOf("X-Token" to "abc", "Referer" to "http://x"), StreamResolver.parseHeaders("X-Token: abc\n bad line \nReferer: http://x\n: nothing\nA B: c"))
        assertEquals("Basic dXNlcjpwYXNz", Http.basic("user", "pass"))
        assertTrue(Http.isLocal("192.168.1.5")); assertTrue(Http.isLocal("nas.local")); assertTrue(Http.isLocal("172.20.0.1")); assertFalse(Http.isLocal("example.com")); assertFalse(Http.isLocal("172.40.0.1"))
        assertNull(Http.makeProxy("NONE", "h", 80)); assertNull(Http.makeProxy("HTTP", "", 80)); assertNull(Http.makeProxy("HTTP", "h", 0))
        assertEquals(java.net.Proxy.Type.SOCKS, Http.makeProxy("SOCKS", "h", 1080)!!.type())
        assertEquals(SourceType.PLEX, SourceType.fromLabel("Plex")); assertEquals(SourceType.XTREAM, SourceType.fromLabel("unknown")); assertNotNull(SourceType.entries.map { it.label }.toSet().size == SourceType.entries.size)
    }
}

class ChannelHealthTests {
    private val ts = byteArrayOf(0x47, 0, 0x11, 0x10)
    @Test fun classifiesWhatCameBack() {
        assertEquals(Health.Ok(200), ChannelHealthCheck.classify(200, ts, 200, null))
        assertEquals(Health.Slow(4000), ChannelHealthCheck.classify(200, ts, 4000, null))
        assertEquals(Health.Silent, ChannelHealthCheck.classify(null, ByteArray(0), 10_000, java.net.SocketTimeoutException()))
        assertEquals(Health.Silent, ChannelHealthCheck.classify(200, ByteArray(0), 100, null))
        assertEquals(Health.Dead("Server answered 404"), ChannelHealthCheck.classify(404, ByteArray(0), 50, null))
        assertEquals(Health.Dead("Unknown host"), ChannelHealthCheck.classify(null, ByteArray(0), 50, java.net.UnknownHostException()))
        assertEquals(Health.Dead("Not a video stream"), ChannelHealthCheck.classify(200, "<html>sorry".toByteArray(), 50, null))
        assertEquals(Health.Ok(80), ChannelHealthCheck.classify(200, "#EXTM3U\n#EXT-X-VERSION:3".toByteArray(), 80, null))     // an HLS playlist is fine
        assertTrue(Health.Silent !is Health.Dead)
    }
}
