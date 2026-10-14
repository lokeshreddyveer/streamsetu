package app.streamsetu.core

import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.parse.M3uParser
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.XmltvParser
import org.junit.Assert.*
import org.junit.Test

class ParsingTests {
    private val sample = """
        #EXTM3U
        #EXTINF:-1 tvg-id="bbc.one" tvg-name="BBC One" tvg-logo="http://x/bbc.png" tvg-chno="1" group-title="UK",BBC One HD
        http://host:8080/live/u/p/1.m3u8
        #EXTINF:-1 group-title="Movies, Action",Die Hard (1988)
        http://host:8080/movie/u/p/77.mkv
        #EXTINF:-1 group-title="Shows",Show S01E02
        http://host:8080/series/u/p/88.mp4
        #EXTGRP:Sport
        #EXTINF:-1,Sky Sports
        http://host/stream.ts
    """.trimIndent()

    @Test fun readsChannelsMoviesAndEpisodes() {
        val e = M3uParser.parse(sample)
        assertEquals(4, e.size)
        assertEquals("BBC One HD", e[0].name); assertEquals("bbc.one", e[0].tvgId); assertEquals(1, e[0].channelNumber); assertEquals("UK", e[0].group)
        assertEquals(ContentKind.CHANNEL, e[0].kind)
        assertEquals(ContentKind.MOVIE, e[1].kind); assertEquals("Movies, Action", e[1].group); assertEquals("Die Hard (1988)", e[1].name)
        assertEquals(ContentKind.EPISODE, e[2].kind)
        assertEquals("Sport", e[3].group)
    }

    @Test fun commaInsideQuotesDoesNotCutTheTitle() {
        val e = M3uParser.parse("#EXTINF:-1 tvg-name=\"A, B\" group-title=\"X\",Real Title\nhttp://h/1")
        assertEquals("Real Title", e.single().name)
    }

    @Test fun entriesWithoutAnAddressAreSkipped() {
        assertEquals(0, M3uParser.parse("#EXTINF:-1,Lonely\n#EXTINF:-1,Also lonely").size)
    }

    @Test fun xtreamAddressesAreBuilt() {
        assertEquals("http://h:80/live/u/p/5.m3u8", Xtream.streamUrl("h:80", "u", "p", "live:5:m3u8"))
        assertEquals("http://h/movie/u/p/9.mkv", Xtream.streamUrl("http://h/", "u", "p", "movie:9:mkv"))
        assertEquals("http://h/player_api.php?username=u&password=p%26q&action=get_live_streams", Xtream.api("http://h/player_api.php", "u", "p&q", "get_live_streams"))
        assertNull(Xtream.streamUrl("h", "u", "p", "bad"))
    }

    @Test fun xtreamListsAcceptArraysAndKeyedObjects() {
        assertEquals(2, Xtream.parseArray("""[{"a":1},{"a":2}]""").size)
        assertEquals(2, Xtream.parseArray("""{"1":{"a":1},"2":{"a":2}}""").size)
        assertEquals(0, Xtream.parseArray("not json").size)
    }

    @Test fun guideTimesAreReadWithAndWithoutZone() {
        assertEquals(1_792_000_000_000L / 1000 * 0 + XmltvParser.parseTime("20261013180000 +0000"), XmltvParser.parseTime("20261013180000"))
        assertEquals(XmltvParser.parseTime("20261013180000 +0000") - 2 * 3600_000, XmltvParser.parseTime("20261013180000 +0200"))
    }

    @Test fun adultCategoryNamesAreRecognised() {
        for (n in listOf("XXX", "Adults 18+", "Adult Movies", "PORN HD")) assertTrue(n, app.streamsetu.core.data.repo.ParentalControls.isAdultName(n))
        for (n in listOf("Sports", "Essex News", "Kids", "Sussex")) assertFalse(n, app.streamsetu.core.data.repo.ParentalControls.isAdultName(n))
    }

    @Test fun anM3uGuideAddressIsReadFromTheHeader() {
        var found: String? = null
        M3uParser.parse(sequenceOf("#EXTM3U url-tvg=\"http://g/epg.xml.gz,http://h/x.xml\"", "#EXTINF:-1,A", "http://s/1"), onHeader = { found = it }) {}
        assertEquals("http://g/epg.xml.gz", found)
    }
}
