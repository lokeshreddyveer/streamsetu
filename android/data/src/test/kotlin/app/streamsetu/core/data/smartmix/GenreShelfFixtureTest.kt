package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File

/** The genre shelf contract (docs/SMART-MIX.md) against the shared fixtures produced by the Swift reference: every number must match. */
class GenreShelfFixtureTest {
    private fun doc(name: String): JsonObject? { val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir); return Json.parseToJsonElement(File(dir, "$name.json").readText()).jsonObject }
    private fun strs(e: JsonElement?) = e!!.jsonArray.map { it.jsonPrimitive.content }
    private fun JsonElement?.s() = if (this == null || this is JsonNull) null else jsonPrimitive.content

    private fun library(d: JsonObject) = d["library"]!!.jsonArray.map { e -> val o = e.jsonObject; FixtureRunner.toCandidate(o).copy(genres = GenreShelves.tokens(o["genres"].s())) }

    private fun diagMap(d: ShelfDiagnostics): Map<String, Any> = mapOf("camOnly" to d.camOnly, "caption" to d.caption, "dismissed" to d.dismissed, "drawn" to d.drawn, "groups" to d.groups, "hidden" to d.hidden,
        "noArtwork" to d.noArtwork, "pool" to d.pool, "restricted" to d.restricted, "tier" to d.tier, "trendMode" to d.trendMode, "watched" to d.watched)

    private fun run(lib: List<Candidate>, st: JsonObject, view: ShelfView): ShelfResult {
        val ranks = st["ranks"]?.jsonObject?.mapValues { it.value.jsonPrimitive.int } ?: emptyMap()
        val members = lib.map { it.copy(trendingRank = ranks[it.id]) }
        val ctx = Context(st["profile"].s()!!, st["dayKey"].s()!!, st["refreshCounter"]?.jsonPrimitive?.int ?: 0)
        return SmartMixEngine.buildShelf(IdentityGrouping.prepare(members, null), st["shelf"].s()!!, ctx, false, view)
    }

    private fun checkStep(lib: List<Candidate>, st: JsonObject, view: ShelfView, where: String) {
        val exp = st["expect"]!!.jsonObject
        val out = run(lib, st, view)
        assertEquals("$where ids", strs(exp["ids"]), out.ids)
        val want = exp["diag"]!!.jsonObject.mapValues { (_, v) -> val p = v.jsonPrimitive; if (p.isString) p.content else p.booleanOrNull ?: p.int }
        assertEquals("$where diag", want, diagMap(out.diagnostics).filterKeys { it in want.keys })
    }

    @Test fun tableMatchesTheFixture() {
        val d = doc("genre-shelves")!!
        val t = d["table"]!!.jsonArray
        assertEquals(t.size, GenreTable.all.size)
        for ((i, e) in t.withIndex()) {
            val o = e.jsonObject; val g = GenreTable.all[i]
            assertEquals(o["key"].s(), g.key); assertEquals(o["title"].s(), g.title); assertEquals(o["scope"].s(), g.scope.name.lowercase()); assertEquals(strs(o["aliases"]), g.aliases)
            assertEquals(o["kids"]!!.jsonPrimitive.boolean, g.kids); assertEquals(o["tmdbMovie"]!!.jsonArray.map { it.jsonPrimitive.int }, g.tmdbMovie)
            assertEquals(o["tmdbTV"]!!.jsonArray.map { it.jsonPrimitive.int }, g.tmdbTV); assertEquals(o["tmdbLang"].s(), g.tmdbLang)
        }
        val c = d["constants"]!!.jsonObject
        assertEquals(c["maxFromAffinity"]!!.jsonPrimitive.int, GenreShelves.MAX_FROM_AFFINITY); assertEquals(c["maxShown"]!!.jsonPrimitive.int, GenreShelves.MAX_SHOWN)
        assertEquals(c["minTitles"]!!.jsonPrimitive.int, GenreShelves.MIN_TITLES); assertEquals(c["rankBucket"]!!.jsonPrimitive.int, GenreShelves.RANK_BUCKET); assertEquals(c["shelfSize"]!!.jsonPrimitive.int, GenreShelves.SHELF_SIZE)
        assertEquals(listOf("action", "comedy", "drama", "thriller", "scifi", "horror", "romance", "crime", "animation", "documentary", "family", "fantasy", "mystery", "adventure", "war", "western", "history", "music", "biography", "kids", "anime", "reality"), GenreTable.all.map { it.key })
    }

    @Test fun tokensAndMatching() {
        val d = doc("genre-shelves")!!
        for (e in d["tokens"]!!.jsonArray) { val o = e.jsonObject; assertEquals(o["raw"].s(), strs(o["tokens"]), GenreShelves.tokens(o["raw"].s())) }
        for (e in d["matching"]!!.jsonArray) { val o = e.jsonObject; assertEquals(o.toString(), strs(o["keys"]), GenreShelves.keysFor(strs(o["tokens"]), o["kind"].s() == "series")) }
    }

    @Test fun countsSelectAndPlacement() {
        val d = doc("genre-shelves")!!
        val groups = IdentityGrouping.prepare(library(d), null).groups
        assertEquals(d["counts"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }, GenreShelves.counts(groups).filterValues { it > 0 })
        for (e in d["select"]!!.jsonArray) {
            val o = e.jsonObject
            val counts = o["counts"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
            val got = GenreShelves.select(counts, o["profile"].s()!!, o["dayKey"].s()!!, o["refreshCounter"]?.jsonPrimitive?.int ?: 0, o["kids"]?.jsonPrimitive?.booleanOrNull ?: false, o["affinityGenreKeys"]?.let { strs(it) } ?: emptyList())
            assertEquals(o.toString().take(200), strs(o["expect"]), got)
        }
        for (e in d["placement"]!!.jsonArray) { val o = e.jsonObject; assertEquals(strs(o["expect"]), GenreShelves.placement(strs(o["present"]).toSet(), strs(o["genres"]))) }
    }

    @Test fun genreShelfSteps() {
        val d = doc("genre-shelves")!!
        val lib = library(d)
        for ((n, st) in d["steps"]!!.jsonArray.withIndex()) checkStep(lib, st.jsonObject, ShelfView.WEEKLY, "genre-shelves step $n")
    }

    @Test fun bothViewsOfGenreShelvesAndTrendingLibrary() {
        val d = doc("shelf-modes")!!
        val lib = library(d)
        for ((n, st) in d["steps"]!!.jsonArray.withIndex()) checkStep(lib, st.jsonObject, ShelfView.parse(st.jsonObject["mode"].s()), "shelf-modes step $n")
    }

    @Test fun rememberedChoiceListNamesAndRefetchHours() {
        val d = doc("shelf-modes")!!
        val mem = HashMap<String, String>()
        val store = ShelfModeStore({ mem[it] }, { k, v -> if (v == null) mem.remove(k) else mem[k] = v })
        for (e in d["storage"]!!.jsonArray) {
            val o = e.jsonObject
            if (o["op"].s() == "set") store.set(o["profile"].s()!!, o["shelf"].s()!!, ShelfView.parse(o["mode"].s()))
            else assertEquals(o.toString(), ShelfView.parse(o["expect"].s()), store.mode(o["profile"].s()!!, o["shelf"].s()!!))
        }
        // docs/SMART-MIX.md 10.6: a tap on either segment is stored, "This week" included (the older "weekly removes the entry" wording in section 4 is superseded)
        assertEquals("weekly", mem["smartmix.mode.a.genre:thriller"])
        for (e in d["lists"]!!.jsonArray) { val o = e.jsonObject; assertEquals(o.toString(), o["own"].s() to o["general"].s(), GenreShelves.listNames(o["shelf"].s()!!, ShelfView.parse(o["mode"].s()))) }
        for ((k, v) in d["refetchHours"]!!.jsonObject) assertEquals(k, v.jsonPrimitive.int, GenreShelves.refetchHours(k))
    }
}
