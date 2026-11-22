package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File

class FeaturesTest {
    private fun i(e: JsonElement): Int? = e.jsonPrimitive.intOrNull
    private fun s(e: JsonElement): String? = if (e is JsonNull) null else e.jsonPrimitive.content

    @Test fun sharedFeatureTables() {
        val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir)
        val j = Json.parseToJsonElement(File(dir, "features.json").readText()).jsonObject
        for (r in j["release"]!!.jsonArray) { val a = r.jsonArray; assertEquals("release ${a[0]}", i(a[2]), Features.release(i(a[0]), i(a[1])!!)) }
        for (r in j["added"]!!.jsonArray) { val a = r.jsonArray; assertEquals("added ${a[0]}", i(a[1]), Features.added(i(a[0]))) }
        for (r in j["quality"]!!.jsonArray) { val a = r.jsonArray; assertEquals(i(a[1]), Features.quality(i(a[0])!!)) }
        for (r in j["language"]!!.jsonArray) { val a = r.jsonArray; assertEquals(i(a[2]), Features.language(s(a[0]), s(a[1]))) }
        for (r in j["rating"]!!.jsonArray) { val a = r.jsonArray; assertEquals("rating <${s(a[0])}>", i(a[1]), Features.rating(s(a[0]))) }
        for (r in j["popularity"]!!.jsonArray) { val a = r.jsonArray; assertEquals(i(a[2]), Features.popularity(i(a[0])!!, i(a[1])!!)) }
        for (r in j["fresh"]!!.jsonArray) { val a = r.jsonArray; assertEquals(i(a[1]), Features.fresh(i(a[0]))) }
        val ac = j["affinityContext"]!!.jsonObject
        val aff = Affinity(ac["topLangs"]!!.jsonArray.map { it.jsonPrimitive.content }, ac["topFolders"]!!.jsonArray.map { it.jsonPrimitive.content },
            ac["topGenres"]!!.jsonArray.map { it.jsonPrimitive.content }, ac["topDecades"]!!.jsonArray.map { it.jsonPrimitive.int })
        for (r in j["affinity"]!!.jsonArray) {
            val a = r.jsonArray; val o = a[0].jsonObject
            val c = Candidate("x", lang = s(o["lang"]!!), folderKey = s(o["folder"]!!), primaryGenre = s(o["genre"]!!), year = i(o["year"]!!))
            assertEquals(i(a[1]), Features.affinity(c, aff))
        }
    }
    @Test fun ratingTable() {
        for (junk in listOf("", "0", "10", "10.0", "abc", "-1", ">10", "N/A", "100", "1.234", "1.", ".5", "٣.5", " 7", null)) assertEquals("<$junk>", 500, Features.rating(junk))
        assertEquals(99, Features.parseTenths("9.99")); assertEquals(5, Features.parseTenths("0.5")); assertNull(Features.parseTenths("10.0"))
        assertEquals(548, Features.rating("7.0")); assertEquals(687, Features.rating("9.99")); assertEquals(300, Features.rating("1.0"))
        assertEquals(496, Features.rating("5.9"))      // negative remainder truncates toward zero
    }
    @Test fun affinityParts() {
        val a = Affinity(listOf("Telugu", "Hindi", "Tamil", "Malayalam"), listOf("f1"), listOf("drama"), listOf(2020))
        fun f(c: Candidate) = Features.affinity(c, a)
        assertEquals(400, f(Candidate("x", lang = "Telugu", year = 1990))); assertEquals(250, f(Candidate("x", lang = "Tamil", year = 1990)))
        assertEquals(0, f(Candidate("x", lang = "Malayalam", year = 1990))); assertEquals(200, f(Candidate("x", folderKey = "f1")))
        assertEquals(100, f(Candidate("x", primaryGenre = "drama"))); assertEquals(150, f(Candidate("x", year = 2029)))
        assertEquals(850, f(Candidate("x", lang = "Telugu", year = 2024, primaryGenre = "drama", folderKey = "f1")))
    }
}
