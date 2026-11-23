package app.streamsetu.core.data.repo

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class DisplayRatingTests {
    @Test fun everySharedDisplayRatingFixtureComesOutExactly() {
        var d: File? = File("").absoluteFile; var f: File? = null
        while (d != null && f == null) { File(d, "artwork/fixtures/display-rating.json").takeIf { it.isFile }?.let { f = it }; d = d.parentFile }
        assumeTrue("the shared fixtures are not next to this checkout", f != null)
        val cases = Json.parseToJsonElement(f!!.readText()).jsonArray
        assertTrue(cases.size >= 18)
        val bad = cases.mapNotNull { e -> val o = e.jsonObject
            val got = DisplayRating.value(o["tmdbAverage"]?.jsonPrimitive?.doubleOrNull, o["tmdbVotes"]?.jsonPrimitive?.intOrNull, o["provider"]?.jsonPrimitive?.contentOrNull)
            val want = o["expected"]?.jsonPrimitive?.doubleOrNull
            if (got == want) null else "$o -> $got" }
        assertTrue("differ:\n" + bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun theTitlePageUsesTheSameRule() {
        assertEquals("8.2", TmdbCast.Details(emptyList(), null, rating = 8.2).ratingOr("5.5"))
        assertEquals("5.5", TmdbCast.Details(emptyList(), null, rating = null).ratingOr("5.5"))
        assertNull(TmdbCast.Details(emptyList(), null).ratingOr("10.0"))
    }
}
