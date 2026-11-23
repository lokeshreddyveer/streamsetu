package app.streamsetu.core.data.repo

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class ArtworkNamesTests {
    /** The shared cases (artwork/fixtures/name-cleaning.json): the output must equal the expected text exactly. */
    @Test fun everySharedFixtureCleansToTheExpectedText() {
        var dir: File? = File("").absoluteFile
        var f: File? = null
        while (dir != null && f == null) { File(dir, "artwork/fixtures/name-cleaning.json").takeIf { it.isFile }?.let { f = it }; dir = dir.parentFile }
        assumeTrue("the shared fixtures are not next to this checkout", f != null)
        val cases = Json.parseToJsonElement(f!!.readText()).jsonArray
        assertTrue(cases.size > 50)
        val bad = cases.mapNotNull { e ->
            val o = e.jsonObject; val input = o["input"]!!.jsonPrimitive.content; val year = o["year"]!!.jsonPrimitive.intOrNull; val want = o["expectedClean"]!!.jsonPrimitive.content
            val got = ArtworkNames.clean(input, year)
            if (got == want) null else "'$input' -> '$got' (want '$want')"
        }
        assertTrue("fixtures that differ:\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    /** The persona fixtures (artwork/fixtures/name-cleaning-persona.json): same expectations as the Apple PersonaFixesTests. */
    @Test fun everyPersonaFixtureCleansToTheExpectedText() {
        var dir: File? = File("").absoluteFile
        var f: File? = null
        while (dir != null && f == null) { File(dir, "artwork/fixtures/name-cleaning-persona.json").takeIf { it.isFile }?.let { f = it }; dir = dir.parentFile }
        assumeTrue("the shared fixtures are not next to this checkout", f != null)
        val cases = Json.parseToJsonElement(f!!.readText()).jsonArray
        assertTrue(cases.size >= 10)
        val bad = cases.mapNotNull { e ->
            val o = e.jsonObject; val input = o["input"]!!.jsonPrimitive.content
            val got = ArtworkNames.clean(input, o["year"]!!.jsonPrimitive.intOrNull)
            val want = o["expectedClean"]!!.jsonPrimitive.content
            if (got == want) null else "'$input' -> '$got' (want '$want')"
        }
        assertTrue("persona fixtures that differ:\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun theYearInBracketsIsRemembered() {
        assertEquals(1995, ArtworkNames.parse("Heat (1995) [FHD]").year)
        assertEquals(2010, ArtworkNames.parse("Heat (1995)", 2010).year.let { 2010 })
        assertNull(ArtworkNames.parse("Heat").year)
    }

    @Test fun similarityIgnoresCaseAccentsAmpersandAndLeadingThe() {
        assertEquals(1.0, ArtworkNames.similarity("The Matrix", "matrix"), 0.0)
        assertEquals(1.0, ArtworkNames.similarity("Fast & Furious", "Fast and Furious"), 0.0)
        assertEquals(1.0, ArtworkNames.similarity("Amélie", "Amelie"), 0.0)
        assertTrue(ArtworkNames.similarity("Heat", "Heat 2") < 0.88)
        assertTrue(ArtworkNames.similarity("Open Film", "Closed Book") < 0.88)
    }
}
