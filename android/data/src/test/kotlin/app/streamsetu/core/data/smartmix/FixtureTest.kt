package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class FixtureTest {
    private fun diagMap(d: ShelfDiagnostics): Map<String, Any> = mapOf(
        "inCount" to d.inCount, "groups" to d.groups, "restricted" to d.restricted, "dismissed" to d.dismissed, "camOnly" to d.camOnly, "noArtwork" to d.noArtwork,
        "watched" to d.watched, "lang" to d.lang, "notTrending" to d.notTrending, "pool" to d.pool, "drawn" to d.drawn, "tier" to d.tier, "tiny" to d.tiny,
        "hidden" to d.hidden, "fallback" to d.fallback, "diversityRelaxed" to d.diversityRelaxed, "caption" to d.caption, "tmdb" to d.tmdb, "trendMode" to d.trendMode)

    private fun expectedDiag(o: JsonObject): Map<String, Any> = (mapOf<String, Any>("trendMode" to false) + o.mapValues { (_, v) ->
        val p = v.jsonPrimitive
        if (p.isString) p.content else p.booleanOrNull ?: p.int
    })   // the reference omits trendMode on the early lang-pref-hidden return

    private fun sha(ids: Map<String, List<String>>, shelves: List<String>): String {
        val h = MessageDigest.getInstance("SHA-256")
        for (s in shelves) { h.update("$s:".toByteArray()); h.update(ids[s]!!.joinToString("\n").toByteArray()); h.update("\n".toByteArray()) }
        return h.digest().joinToString("") { "%02x".format(it) }
    }

    fun check(file: File) {
        val doc = Json.parseToJsonElement(file.readText()).jsonObject
        val outs = FixtureRunner.run(doc)
        val steps = doc["steps"]!!.jsonArray
        for ((n, st) in steps.withIndex()) {
            val exp = st.jsonObject["expect"]!!.jsonObject
            val out = outs[n]
            val where = "${file.name} step $n"
            if (exp.containsKey("digest")) {
                val shelves = st.jsonObject["shelves"]!!.jsonArray.map { it.jsonPrimitive.content }
                for ((k, v) in exp["counts"]!!.jsonObject) assertEquals("$where count $k", v.jsonPrimitive.int, out.ids[k]!!.size)
                for ((k, v) in exp["first"]!!.jsonObject) assertEquals("$where first $k", v.jsonArray.map { it.jsonPrimitive.content }, out.ids[k]!!.take(14))
                assertEquals("$where digest", exp["digest"]!!.jsonPrimitive.content, sha(out.ids, shelves))
            } else {
                for ((shelf, e) in exp) {
                    val o = e.jsonObject
                    assertEquals("$where ids $shelf", o["ids"]!!.jsonArray.map { it.jsonPrimitive.content }, out.ids[shelf])
                    assertEquals("$where art $shelf", o["art"]!!.jsonArray.map { it.jsonPrimitive.content }, out.art[shelf])
                    assertEquals("$where diag $shelf", expectedDiag(o["diag"]!!.jsonObject), diagMap(out.diag[shelf]!!))
                }
            }
        }
    }

    private fun fixture(name: String) {
        val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir)
        check(File(dir, "$name.json"))
    }

    @Test fun emptyLibrary() = fixture("empty-library")
    @Test fun tinyLibrary() = fixture("tiny-library")
    @Test fun duplicatesAndTwins() = fixture("duplicates-and-twins")
    @Test fun multilangVersions() = fixture("multilang-versions")
    @Test fun badRatings() = fixture("bad-ratings")
    @Test fun missingArtwork() = fixture("missing-artwork")
    @Test fun trendingMatched() = fixture("trending-matched")
    @Test fun offlineNoTmdbKey() = fixture("offline-no-tmdb-key")
    @Test fun expiredMetadata() = fixture("expired-metadata")
    @Test fun profileSwitch() = fixture("profile-switch")
    @Test fun exclusions() = fixture("exclusions")
    @Test fun repeatSuppression5Loads() = fixture("repeat-suppression-5-loads")
    @Test fun reshuffleSequence() = fixture("reshuffle-sequence")
    @Test fun dayRollover() = fixture("day-rollover")
    @Test fun diversityLimits() = fixture("diversity-limits")
    @Test fun nonLatinIdsByteOrder() = fixture("non-latin-ids-byte-order")
    @Test fun relaxationOrder() = fixture("relaxation-order")
    @Test fun smallMixed300() = fixture("small-mixed-300")
    @Test fun hundredsOfFolders() = fixture("hundreds-of-folders")
    @Test fun large66k() = fixture("large-66k")
    @Test fun stress200k() = fixture("stress-200k")

    @Test fun everyFixtureFileIsCovered() {
        val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir)
        val covered = javaClass.declaredMethods.map { it.name }.toSet()
        val names = dir!!.listFiles { f -> f.extension == "json" }!!.map { it.nameWithoutExtension }.filter { it != "prng" && it != "features" }
        // a new fixture added by the shared set must get a test here
        val camel = { s: String -> s.split('-').mapIndexed { i, p -> if (i == 0) p else p.replaceFirstChar { it.uppercase() } }.joinToString("") }
        val missing = names.filter { camel(it) !in covered && camel(it).replace("5Loads", "5Loads") !in covered }
        assertTrue("fixtures without a Kotlin test: $missing", missing.isEmpty())
    }
}
