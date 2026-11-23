package app.streamsetu.core.data.repo

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class AliasIndexTests {
    private fun fixture(name: String): File? { var d: File? = File("").absoluteFile; while (d != null) { File(d, "artwork/fixtures/$name").takeIf { it.isFile }?.let { return it }; d = d.parentFile }; return null }
    private fun index() = AliasIndex.parse(fixture("alias-index-mini.tsv")!!.readBytes())!!

    @Test fun keysAndLookupsFollowTheSharedCases() {
        assumeTrue("the shared fixtures are not next to this checkout", fixture("alias-cases.json") != null)
        val j = Json.parseToJsonElement(fixture("alias-cases.json")!!.readText()).jsonObject
        for (p in j["keys"]!!.jsonArray) assertEquals(p.jsonArray[0].jsonPrimitive.content, p.jsonArray[1].jsonPrimitive.content, AliasKey.make(p.jsonArray[0].jsonPrimitive.content))
        val idx = index(); val bad = ArrayList<String>()
        for (c in j["cases"]!!.jsonArray) {
            val o = c.jsonObject; val name = o["name"]!!.jsonPrimitive.content; val series = o["series"]!!.jsonPrimitive.boolean
            val got = idx.resolve(name, series); val e = o["expect"]?.takeIf { it !is JsonNull }?.jsonObject
            val ok = if (e == null) got == null else got?.first?.tmdbId == e["id"]!!.jsonPrimitive.long && got.second.name.lowercase() == e["tier"]!!.jsonPrimitive.content
            if (!ok) bad.add("$name series=$series got=$got")
        }
        assertTrue(bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun aGzipFileLoadsLikeThePlainOne() {
        assumeTrue(fixture("alias-index-mini.tsv.gz") != null)
        val b = AliasIndex.parse(fixture("alias-index-mini.tsv.gz")!!.readBytes())!!
        assertEquals(20, b.count); assertEquals(155L, b.exact("The Dark Knight", false)?.tmdbId)
    }
}

class QueryTierTests {
    private fun fixture(name: String): File? { var d: File? = File("").absoluteFile; while (d != null) { File(d, "artwork/fixtures/$name").takeIf { it.isFile }?.let { return it }; d = d.parentFile }; return null }
    @Test fun tiersFollowTheSharedCases() {
        assumeTrue(fixture("query-tiers.json") != null)
        for (c in Json.parseToJsonElement(fixture("query-tiers.json")!!.readText()).jsonArray) {
            val o = c.jsonObject
            assertEquals(o["text"]!!.jsonPrimitive.content, o["expect"]!!.jsonArray.map { it.jsonPrimitive.content }, TmdbMatcher.extraQueries(o["text"]!!.jsonPrimitive.content, o["tiers"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()))
        }
    }
    @Test fun nonTitlesAreRecognisedAndRealTitlesAreNot() {
        for (t in listOf("Rovers vs United", "Lions vs. Tigers Highlights", "League Final Press Conference", "Boxing Night PPV 12")) assertTrue(t, TmdbMatcher.isNonTitle(t, null))
        for (t in listOf("Alien vs. Predator (2004)", "Batman v Superman", "The Heat", "Live Free or Die Hard")) assertFalse(t, TmdbMatcher.isNonTitle(t, null))
    }
}
