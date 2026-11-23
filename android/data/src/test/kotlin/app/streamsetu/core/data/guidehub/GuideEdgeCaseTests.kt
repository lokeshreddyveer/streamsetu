package app.streamsetu.core.data.guidehub

import org.junit.Assert.*
import org.junit.Test
import org.xmlpull.v1.XmlPullParserException
import java.time.Instant

/** Small inline guides for the awkward cases (no files, no network): each test is a few milliseconds. */
class GuideEdgeCaseTests {
    private fun ms(s: String) = Instant.parse(s).toEpochMilli()
    private fun decode(xml: String, from: Long = 0, to: Long = 4_000_000_000_000, zone: String? = null): Pair<GuideReadStats, List<GuideProgramme>> {
        val out = ArrayList<GuideProgramme>()
        val st = XmltvDecoder.read(xml.byteInputStream(), from, to, zone) { out += it }
        return st to out
    }
    private fun prog(start: String, stop: String, title: String = "T") = """<programme start="$start" stop="$stop" channel="c"><title>$title</title></programme>"""
    private fun tv(vararg body: String) = """<?xml version="1.0"?><tv>${body.joinToString("")}</tv>"""

    @Test fun oddOffsetsAreExact() {
        val noon = ms("2026-11-22T12:00:00Z")
        assertEquals(noon - 19_800_000, XmltvTime.parse("20261122120000 +0530"))
        assertEquals(noon + 13_500_000, XmltvTime.parse("20261122120000 -0345"))
        assertEquals(noon - 14 * 3_600_000, XmltvTime.parse("20261122120000 +1400"))
        assertEquals(noon - 3_600_000, XmltvTime.parse("20261122120000+01:00"))
        assertEquals(noon - 3_600_000, XmltvTime.parse("20261122120000 +01"))
        assertEquals(noon, XmltvTime.parse("20261122120000 GMT"))
        assertEquals(noon - 12 * 3_600_000, XmltvTime.parse("202611220000"))                    // minutes only: no seconds
    }
    @Test fun garbageTimesAreRefusedNotGuessed() {
        for (bad in listOf("", "soon", "20261322120000", "20261122250000", "20261122126000", "20261232120000", "20261122120000 +1500", "20261122120000 +0560", "18991122120000", "22001122120000", "2026-11-22 12:00", "20260230120000"))
            assertNull(bad, XmltvTime.parse(bad))
    }
    @Test fun localZoneHandlesTheClockGoingBackAndForward() {
        // 2026-03-29 01:30 does not exist in Paris (clocks jump 02:00 to 03:00); it must still give one instant, not throw
        assertNotNull(XmltvTime.parse("20260329013000", "Europe/Paris")); assertNotNull(XmltvTime.parse("20260329023000", "Europe/Paris"))
        // 2026-10-25 02:30 happens twice; one of the two is taken
        val t = XmltvTime.parse("20261025023000", "Europe/Paris")!!
        assertTrue(t == ms("2026-10-25T00:30:00Z") || t == ms("2026-10-25T01:30:00Z"))
        assertEquals("a name that is not a zone means UTC", ms("2026-11-22T12:00:00Z"), XmltvTime.parse("20261122120000", "Not/AZone"))
        assertEquals("an offset beats the zone", ms("2026-11-22T12:00:00Z"), XmltvTime.parse("20261122120000 +0000", "Asia/Kolkata"))
        assertEquals(ms("2026-11-22T06:30:00Z"), XmltvTime.parse("20261122120000", "Asia/Kolkata"))
    }
    @Test fun leapSecondIsAccepted() { assertEquals(ms("2026-12-31T23:59:59Z"), XmltvTime.parse("20261231235960")) }

    @Test fun programmeWithBackwardsOrMissingTimesIsCountedInvalid() {
        val (st, p) = decode(tv(prog("20261122120000", "20261122110000"), """<programme channel="c"><title>x</title></programme>""", prog("20261122120000", "20261122130000", "ok")))
        assertEquals(3, st.programmesSeen); assertEquals(1, st.programmesKept); assertEquals(2, st.droppedInvalid); assertEquals("ok", p.single().title)
    }
    @Test fun windowEdgesAreInclusiveOfWhatOverlaps() {
        val now = ms("2026-11-22T12:00:00Z")
        val (st, p) = decode(tv(prog("20261122100000", "20261122110000", "ended"), prog("20261122110000", "20261122130000", "running"), prog("20261125120000", "20261125130000", "later")), now, now + 86_400_000)
        assertEquals(listOf("running"), p.map { it.title }); assertEquals(1, st.droppedPast); assertEquals(1, st.droppedFuture)
    }
    @Test fun entitiesAndCdataAreReadAsText() {
        val (_, p) = decode(tv("""<programme start="20261122120000" stop="20261122130000" channel="c"><title>Tom &amp; Jerry &lt;3</title><desc><![CDATA[a <b> & c]]></desc></programme>"""))
        assertEquals("Tom & Jerry <3", p.single().title); assertEquals("a <b> & c", p.single().description)
    }
    @Test fun malformedFewProgrammesIsAnErrorButLongGuideCutOffIsKept() {
        try { decode("<tv>" + prog("20261122120000", "20261122130000") + "<programme start="); fail("a short broken guide must fail") } catch (e: XmlPullParserException) { }
        val body = StringBuilder("<tv>"); repeat(XmltvDecoder.MIN_FOR_TRUNCATED + 5) { body.append(prog("20261122120000", "20261122130000", "t$it")) }; body.append("<programme start=\"2026")
        val (st, p) = decode(body.toString())
        assertTrue(st.truncated); assertEquals(XmltvDecoder.MIN_FOR_TRUNCATED + 5, p.size)
    }
    @Test fun emptyAndNotXmlAreRefused() {
        for (junk in listOf("", "<html><body>login</body></html>", "plain text, not a guide")) {
            try { decode(junk); fail("accepted: $junk") } catch (e: GuideReadException) { } catch (e: XmlPullParserException) { }
        }
    }
    @Test fun entityDeclarationIsNeverExpanded() {
        val xml = """<?xml version="1.0"?><!DOCTYPE tv [<!ENTITY x SYSTEM "file:///etc/hosts">]><tv>${prog("20261122120000", "20261122130000", "&x;")}</tv>"""
        val r = runCatching { decode(xml) }.getOrNull()
        r?.second?.forEach { assertFalse(it.title.contains("localhost")) }
    }

    // ---- freshness: the boundaries
    private val now = ms("2026-11-22T12:00:00Z")
    private fun fresh(end: Long?, lastOk: Long? = now - 3_600_000, failed: Boolean = false, n: Int = 10, enabled: Boolean = true, interval: Long = 6 * 3600) =
        GuideFreshness.evaluate(FreshnessInput(now, enabled, end, lastOk, failed, interval, n))
    @Test fun freshnessBoundaries() {
        assertEquals("guide.off", fresh(null, enabled = false).key)
        assertEquals("guide.neverUpdated", fresh(null, lastOk = null).key); assertEquals(FreshLevel.ERROR, fresh(null, lastOk = null, failed = true).level)
        assertEquals("guide.empty", fresh(now + 86_400_000, n = 0).key)
        assertEquals("guide.noUpcoming", fresh(now - 1).key)
        assertEquals("guide.endsUnder3h", fresh(now + 3 * 3_600_000 - 1).key)
        assertEquals("a guide ending in exactly 3 hours is not yet short", "guide.fresh", fresh(now + 3 * 3_600_000).key.let { if (it == "guide.endsIn") "guide.fresh" else it })
        assertEquals("guide.updatedLongAgo", fresh(now + 86_400_000, lastOk = now - 25 * 3_600_000).key)
        assertEquals("guide.endsIn", fresh(now + 6 * 3_600_000, lastOk = now - 10 * 3_600_000).key)
        assertEquals("guide.fresh", fresh(now + 48 * 3_600_000).key); assertEquals(48, fresh(now + 48 * 3_600_000).amount)
    }

    // ---- the public channel database never matches a blocked, adult or closed channel
    private fun ch(id: String, name: String, cat: List<String> = emptyList(), nsfw: Boolean = false, closed: String? = null, country: String? = "GB") = IptvChannel(id, name, emptyList(), country, cat, nsfw, closed)
    @Test fun enrichmentNeverMatchesBlockedAdultClosedOrRestricted() {
        val idx = IptvOrgIndex.build(listOf(ch("A.uk", "Alpha"), ch("B.uk", "Bravo", nsfw = true), ch("C.uk", "Charlie", closed = "2020-01-01"), ch("D.uk", "Delta", cat = listOf("xxx")), ch("E.uk", "Echo")), """[{"channel":"E.uk"}]""")
        assertNotNull(IptvOrgEnricher.match("Alpha", null, "GB", false, idx))
        assertNull("restricted", IptvOrgEnricher.match("Alpha", "A.uk", "GB", true, idx))
        for (n in listOf("Bravo" to "B.uk", "Charlie" to "C.uk", "Delta" to "D.uk", "Echo" to "E.uk")) { assertNull(n.first, IptvOrgEnricher.match(n.first, null, null, false, idx)); assertNull(n.first, IptvOrgEnricher.match("zzz", n.second, null, false, idx)) }
    }
    @Test fun emptyOrBrokenBlocklistRefusesToMatchAnything() {
        for (b in listOf<String?>(null, "[]", "not json")) try { IptvOrgIndex.build(listOf(ch("A.uk", "Alpha")), b); fail("built without a block list: $b") } catch (e: BlocklistUnavailable) { }
    }
    @Test fun logoChoiceSkipsInsecureOldAndTinyOnes() {
        val l = listOf(IptvLogo("c", "http://x/a.png", 500, emptyList(), "PNG"), IptvLogo("c", "https://x/old.png", 500, listOf("old"), "PNG"), IptvLogo("c", "https://x/tiny.png", 64, emptyList(), "PNG"), IptvLogo("c", "https://x/s.svg", 900, emptyList(), "SVG"), IptvLogo("c", "https://x/p.png", 256, emptyList(), "PNG"))
        assertEquals("https://x/p.png", IptvOrgEnricher.bestLogo(l)!!.url); assertNull(IptvOrgEnricher.bestLogo(l.take(3)))
    }

    // ---- diagnostics text never carries a secret
    @Test fun messagesRenderEveryKeyWithoutLeavingPlaceholders() {
        for (k in listOf("guide.off", "guide.neverUpdated", "guide.empty", "guide.noUpcoming", "guide.endsUnder3h", "guide.updatedLongAgo", "guide.endsIn", "guide.fresh")) {
            val t = GuideMessages.render(k, 3); assertTrue(k, t.isNotBlank()); assertFalse("$k: $t", t.contains("%") || t.contains("{"))
        }
    }
}
