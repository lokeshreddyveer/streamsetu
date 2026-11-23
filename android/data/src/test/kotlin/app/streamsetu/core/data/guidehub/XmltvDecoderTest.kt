package app.streamsetu.core.data.guidehub

import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File
import java.time.Instant
import java.util.zip.GZIPInputStream

/** The same XMLTV fixtures as the Apple decoder tests. */
class XmltvDecoderTest {
    private fun fx(name: String): File? {
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null) { val f = File(d, "epg/fixtures/$name"); if (f.exists()) return f; d = d.parentFile }
        return null
    }
    private class Out(val stats: GuideReadStats, val channels: List<GuideChannelRecord>, val programmes: List<GuideProgramme>)
    private fun read(name: String, from: Long = 0, to: Long = 4_000_000_000_000, zone: String? = null): Out {
        val f = fx(name); Assume.assumeNotNull(f)
        val ch = ArrayList<GuideChannelRecord>(); val pr = ArrayList<GuideProgramme>()
        val raw = f!!.inputStream().buffered()
        raw.mark(2); val gz = raw.read() == 0x1f && raw.read() == 0x8b; raw.reset()
        val st = XmltvDecoder.read(if (gz) GZIPInputStream(raw) else raw, from, to, zone, { ch += it }) { pr += it }
        return Out(st, ch, pr)
    }
    private fun ms(s: String) = Instant.parse(s).toEpochMilli()

    @Test fun basicFieldsAndDrops() {
        val r = read("xmltv/basic.xml")
        assertEquals(2, r.channels.size)
        assertEquals(listOf("BBC One", "BBC 1"), r.channels[0].displayNames); assertEquals("https://example.test/bbcone.png", r.channels[0].icon)
        assertEquals(5, r.stats.programmesSeen); assertEquals(3, r.stats.programmesKept); assertEquals(2, r.stats.droppedInvalid)
        val p = r.programmes[0]
        assertEquals("Evening News", p.title); assertEquals("Headlines", p.subtitle); assertEquals("News", p.category); assertEquals("en", p.lang); assertEquals("2026", p.date); assertEquals("PG", p.rating)
        assertEquals(ms("2026-11-22T18:00:00Z"), p.startMs); assertEquals(ms("2026-11-22T18:30:00Z"), p.stopMs)
    }
    @Test fun offsetsAndLocalZone() {
        val utc = ms("2026-11-22T12:00:00Z")
        assertEquals(listOf(utc - 3_600_000, utc + 5 * 3_600_000, utc, utc - 19_800_000, utc - 3_600_000, utc), read("xmltv/with-offsets.xml").programmes.map { it.startMs })
        val paris = read("xmltv/with-offsets.xml", zone = "Europe/Paris").programmes.map { it.startMs }
        assertEquals("no offset: Paris wall time", utc - 3_600_000, paris[2]); assertEquals("an offset still wins", utc - 3_600_000, paris[0])
    }
    @Test fun episodeNumbers() { assertEquals(listOf("S02E05", "E08", "Ep 12"), read("xmltv/episode-num.xml").programmes.map { it.episodeNum }) }
    @Test fun hugeTextIsCut() {
        val r = read("xmltv/huge-names.xml")
        assertEquals(XmltvDecoder.MAX_NAME, r.channels[0].displayNames[0].length); assertEquals(XmltvDecoder.MAX_TITLE, r.programmes[0].title.length); assertEquals(XmltvDecoder.MAX_TEXT, r.programmes[0].description!!.length)
    }
    @Test fun gzipReadsLikePlain() { assertEquals(read("xmltv/basic.xml").programmes, read("xmltv/gzip.xml.gz").programmes) }
    @Test fun emptyGuideIsCountedNotHidden() {
        val now = ms("2026-11-22T12:00:00Z")
        val r = read("xmltv/all-past.xml", now - 3 * 3600_000, now + 3 * 86400_000)
        assertEquals(3, r.stats.programmesSeen); assertEquals(0, r.stats.programmesKept); assertEquals(3, r.stats.droppedPast)
        assertEquals(ms("2026-11-12T21:00:00Z"), r.stats.lastStopMs); assertEquals(ms("2026-11-10T20:00:00Z"), r.stats.firstStartMs)
        assertEquals(3, read("xmltv/basic.xml", ms("2026-11-01T00:00:00Z"), ms("2026-11-02T00:00:00Z")).stats.droppedFuture)
    }
    @Test fun invalidChannelsOnlyAndNotAGuide() {
        assertEquals(2, read("xmltv/invalid-times.xml").stats.droppedInvalid)
        assertEquals(2, read("xmltv/channels-only.xml").stats.channels)
        try { read("xmltv/not-a-guide.xml"); fail() } catch (e: GuideReadException) { } catch (e: org.xmlpull.v1.XmlPullParserException) { }
    }
    @Test fun externalEntityIsNotRead() {
        val host = runCatching { File("/etc/hostname").readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() } ?: "never-present"
        val r = runCatching { read("xmltv/dtd-xxe.xml") }.getOrNull()
        if (r != null) assertFalse(r.channels.any { c -> c.displayNames.any { host in it } })
    }
}
