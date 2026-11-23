package app.streamsetu.core.data.repo

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class ArtworkMatchDecisionTests {
    private fun fixture(name: String): File? { var d: File? = File("").absoluteFile; while (d != null) { File(d, "artwork/fixtures/$name").takeIf { it.isFile }?.let { return it }; d = d.parentFile }; return null }

    /** Every case of the shared fixtures must come out exactly: the id, or none. */
    @Test fun everySharedMatchDecisionFixtureComesOutExactly() {
        val f = fixture("match-decision.json"); assumeTrue("the shared fixtures are not next to this checkout", f != null)
        val cases = Json.parseToJsonElement(f!!.readText()).jsonArray
        assertTrue("expected the full set, got ${cases.size}", cases.size >= 133)
        val bad = cases.mapNotNull { e ->
            val o = e.jsonObject
            val q = ArtworkMatchDecision.Query(o["libraryTitle"]!!.jsonPrimitive.content, o["year"]?.jsonPrimitive?.intOrNull, o["kind"]!!.jsonPrimitive.content == "series", o["languageTag"]?.jsonPrimitive?.contentOrNull.orEmpty())
            val cands = o["candidates"]!!.jsonArray.map { c -> c.jsonObject.let { ArtworkMatchDecision.Candidate(it["id"]!!.jsonPrimitive.long, it["title"]?.jsonPrimitive?.contentOrNull, it["originalTitle"]?.jsonPrimitive?.contentOrNull, it["year"]?.jsonPrimitive?.intOrNull, it["popularity"]?.jsonPrimitive?.doubleOrNull ?: 0.0, it["originalLanguage"]?.jsonPrimitive?.contentOrNull) } }
            val want = o["expectedId"]?.jsonPrimitive?.longOrNull
            val got = ArtworkMatchDecision.decide(q, cands, ArtworkNames.clean(q.title, q.year))
            if (got == want) null else "'${q.title}' ${q.year}: got $got want $want (${o["notes"]?.jsonPrimitive?.contentOrNull})"
        }
        assertTrue("${bad.size} of ${cases.size} differ:\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun theNameAloneDecidesAndTheFirstSameNameResultWins() {
        val c = listOf(ArtworkMatchDecision.Candidate(1, "Heat", null, 1996, 50.0, "en"), ArtworkMatchDecision.Candidate(2, "Heat", null, 1972, 500.0, "fr"))
        assertEquals(1L, ArtworkMatchDecision.decide(ArtworkMatchDecision.Query("Heat", 1972, false, "French"), c, "Heat"))
        assertNull(ArtworkMatchDecision.decide(ArtworkMatchDecision.Query("Heat", 1996, false), c, "Cold"))
    }
}
