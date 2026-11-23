package app.streamsetu.core.data.guidehub

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File
import java.time.Instant

/** Parity with the Apple tests: the same `epg/fixtures` files. */
class GuideHubFixtureTest {
    private fun root(): File? {
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null) { val f = File(d, "epg/fixtures"); if (f.isDirectory) return f; d = d.parentFile }
        return null
    }
    private fun json(name: String): JsonObject { val r = root(); Assume.assumeNotNull(r); return Json.parseToJsonElement(File(r, name).readText()).jsonObject }
    private fun s(o: JsonObject, k: String) = o[k]?.jsonPrimitive?.contentOrNull

    @Test fun mappingCases() {
        val j = json("mapping-cases.json")
        val guide = j["guide"]!!.jsonArray.map { it.jsonObject }.map { g ->
            MapGuideChannel(s(g, "source")!!, s(g, "id")!!, g["names"]!!.jsonArray.map { it.jsonPrimitive.content }, s(g, "country"), s(g, "language"), g["priority"]!!.jsonPrimitive.int)
        }
        val cases = j["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 50)
        for (c in cases) {
            val tag = "case ${c["id"]}: ${s(c, "note")}"
            val ch = c["channel"]!!.jsonObject
            val lock = ch["userLock"]?.jsonObject?.let { GuideMatch(s(it, "source")!!, s(it, "xmltv")!!, "user", 1.0, "chosen by you") }
            val channel = MapChannel("c", s(ch, "name")!!, s(ch, "tvg"), s(ch, "provider"), s(ch, "country"), s(ch, "language"), s(ch, "own"),
                ch["alt"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty(), ch["restricted"]?.jsonPrimitive?.booleanOrNull ?: false, lock)
            val r = GuideMappingEngine.map(listOf(channel), guide)[0]
            val e = c["expect"]!!.jsonObject
            when (s(e, "status")) {
                "mapped" -> {
                    val m = r.match ?: fail("$tag: not mapped (${r.unmapped})").let { return }
                    assertEquals(tag, s(e, "source"), m.guideSourceId); assertEquals(tag, s(e, "xmltv"), m.xmltvId); assertEquals(tag, s(e, "method"), m.method)
                    assertEquals(tag, e["confidence"]!!.jsonPrimitive.double, m.confidence, 0.0001)
                }
                "suggested" -> {
                    assertNull(tag, r.match)
                    val sg = r.suggestions.firstOrNull() ?: fail("$tag: no suggestion").let { return }
                    assertEquals(tag, s(e, "xmltv"), sg.xmltvId)
                    assertTrue("$tag ${sg.confidence}", sg.confidence >= e["minConfidence"]!!.jsonPrimitive.double && sg.confidence <= e["maxConfidence"]!!.jsonPrimitive.double)
                }
                else -> { assertNull("$tag matched ${r.match?.xmltvId}", r.match); assertEquals(tag, s(e, "reason"), r.unmapped) }
            }
        }
    }

    @Test fun personaMappingCases() {
        val j = json("mapping-persona.json")
        val guide = j["guide"]!!.jsonArray.map { it.jsonObject }.map { g ->
            MapGuideChannel(s(g, "source")!!, s(g, "id")!!, g["names"]!!.jsonArray.map { it.jsonPrimitive.content }, s(g, "country"), s(g, "language"), g["priority"]!!.jsonPrimitive.int)
        }
        val cases = j["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 5)
        for (c in cases) {
            val tag = "case ${c["id"]}: ${s(c, "note")}"
            val ch = c["channel"]!!.jsonObject
            val channel = MapChannel("c", s(ch, "name")!!, s(ch, "tvg"), s(ch, "provider"), s(ch, "country"), s(ch, "language"), s(ch, "own"), emptyList(), false, null)
            val r = GuideMappingEngine.map(listOf(channel), guide)[0]
            val e = c["expect"]!!.jsonObject
            if (s(e, "status") == "mapped") {
                val m = r.match ?: fail("$tag: not mapped").let { return }
                assertEquals(tag, s(e, "xmltv"), m.xmltvId); assertEquals(tag, s(e, "method"), m.method)
                assertEquals(tag, e["confidence"]!!.jsonPrimitive.double, m.confidence, 0.0001)
            } else assertNull(tag, r.match)
        }
    }

    @Test fun freshnessCases() {
        val j = json("freshness-cases.json")
        for (c in j["cases"]!!.jsonArray.map { it.jsonObject }) {
            fun t(k: String) = s(c, k)?.let { Instant.parse(it).toEpochMilli() }
            val f = GuideFreshness.evaluate(FreshnessInput(t("now")!!, c["enabled"]!!.jsonPrimitive.boolean, t("windowEnd"), t("lastSuccess"), c["lastAttemptFailed"]!!.jsonPrimitive.boolean,
                c["refreshHours"]!!.jsonPrimitive.int * 3600L, c["programmes"]!!.jsonPrimitive.int))
            val e = c["expect"]!!.jsonObject
            assertEquals(s(c, "note"), s(e, "key"), f.key)
            assertEquals(s(c, "note"), s(e, "level"), f.level.name.lowercase())
            e["amount"]?.let { assertEquals(s(c, "note"), it.jsonPrimitive.int, f.amount) }
        }
    }

    @Test fun timeCases() {
        for (c in json("timezone-cases.json")["cases"]!!.jsonArray.map { it.jsonObject }) {
            val zone = if (s(c, "mode") == "local") s(c, "zone") else null
            val want = s(c, "expect")?.let { Instant.parse(it).toEpochMilli() }
            assertEquals("${s(c, "input")} ${s(c, "mode")} $zone", want, XmltvTime.parse(s(c, "input")!!, zone))
        }
    }

    private fun mini(n: String): String { val r = root(); Assume.assumeNotNull(r); return File(r, "iptvorg-mini/$n").readText() }

    @Test fun enrichmentCases() {
        val index = IptvOrgIndex.build(IptvOrgIndex.parseChannels(mini("channels.json")), mini("blocklist.json"), IptvOrgIndex.parseLogos(mini("logos.json")), IptvOrgIndex.parseFeeds(mini("feeds.json")))
        for (c in json("iptvorg-cases.json")["cases"]!!.jsonArray.map { it.jsonObject }) {
            val ch = c["channel"]!!.jsonObject; val e = c["expect"]!!.jsonObject
            val got = IptvOrgEnricher.match(s(ch, "name")!!, s(ch, "tvg"), s(ch, "country"), ch["restricted"]?.jsonPrimitive?.booleanOrNull ?: false, index)
            val note = s(c, "note")
            assertEquals(note, s(e, "match"), got?.dbId)
            if (got != null) {
                assertEquals(note, s(e, "by"), got.matchedBy)
                s(e, "logo")?.let { assertEquals(note, it, got.logoUrl) }
                e["languages"]?.let { assertEquals(note, it.jsonArray.map { x -> x.jsonPrimitive.content }, got.languages) }
                e["timezones"]?.let { assertEquals(note, it.jsonArray.map { x -> x.jsonPrimitive.content }, got.timezones) }
            }
        }
    }

    @Test fun blocklistFailsClosed() {
        val ch = IptvOrgIndex.parseChannels(mini("channels.json"))
        for (bad in listOf(null, "not json", "[]", "{\"a\":1}")) { try { IptvOrgIndex.build(ch, bad); fail("accepted $bad") } catch (e: BlocklistUnavailable) { } }
    }
}
