package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File

/** Home v2 (docs/SMART-MIX.md section 10) against smartmix/fixtures/home-layout.json: placement by weekday and hour, composition, franchise keys, default view, names. Integer-only, so every value must match. */
class HomeLayoutFixtureTest {
    private fun doc(): JsonObject? { val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir); return Json.parseToJsonElement(File(dir, "home-layout.json").readText()).jsonObject }
    private fun strs(e: JsonElement?) = e!!.jsonArray.map { it.jsonPrimitive.content }
    private fun JsonElement?.s() = if (this == null || this is JsonNull) null else jsonPrimitive.content

    @Test fun placementByWeekdayAndHour() {
        for (e in doc()!!["layout"]!!.jsonArray) {
            val o = e.jsonObject
            val out = HomePlacement.layout(strs(o["present"]).toSet(), strs(o["genres"]), strs(o["moods"]), HomeDayContext(o["weekday"]!!.jsonPrimitive.int, o["hour"]!!.jsonPrimitive.int), o["kids"]!!.jsonPrimitive.boolean)
            assertEquals(o["name"].s(), strs(o["expect"]), out)
        }
    }

    private fun pick(o: JsonObject) = HomePick(o["id"].s()!!, o["kind"].s() == "series", o["year"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.int, o["genre"].s(), o["genres"]?.let { strs(it) } ?: emptyList(), o["lang"].s(), o["franchise"].s())

    @Test fun compositionKeepsEachTitleOnceReRanksAndExplores() {
        for (e in doc()!!["compose"]!!.jsonArray) {
            val o = e.jsonObject
            val results = o["results"]!!.jsonArray.map { r -> val ro = r.jsonObject; HomeRowResult(ro["id"].s()!!, ro["picks"]!!.jsonArray.map { pick(it.jsonObject) }, ro["ordered"]?.jsonPrimitive?.boolean ?: false) }
            val aff = o["affinity"]!!.jsonObject
            val rows = HomeCompose.compose(results, HomeAffinity(strs(aff["genreKeys"]), strs(aff["topLangs"])), HomeDayContext(o["weekday"]!!.jsonPrimitive.int, o["hour"]!!.jsonPrimitive.int), o["kids"]!!.jsonPrimitive.boolean)
            val want = o["expect"]!!.jsonArray.map { it.jsonObject["row"].s()!! to strs(it.jsonObject["ids"]) }
            assertEquals(o["name"].s(), want, rows.map { it.row to it.ids })
            // The page contract: no title twice (collections tiles excepted), no row under its minimum, at most 12 rows.
            val all = rows.filter { it.row != ShelfSpec.COLLECTIONS }.flatMap { it.ids }
            assertEquals(o["name"].s(), all.size, all.toSet().size)
            assertTrue(rows.size <= HomePlacement.MAX_ROWS)
            for (r in rows) assertTrue(r.row, r.ids.size >= HomeCompose.minimum(r.row) || r.row == ShelfSpec.COLLECTIONS)
        }
    }

    @Test fun franchiseKeys() {
        for (e in doc()!!["franchise"]!!.jsonArray) { val o = e.jsonObject; assertEquals(o["key"].s(), o["expect"].s(), HomeFranchise.key(o["key"].s()!!)) }
    }

    @Test fun defaultViewOfARankedRow() {
        for (e in doc()!!["modeDefault"]!!.jsonArray) {
            val o = e.jsonObject
            val d = HomeModeDefault.decide(o["chosen"].s()?.let { ShelfView.parse(it) }, o["weeklyOrdered"]!!.jsonPrimitive.boolean, o["allTimeOrdered"]!!.jsonPrimitive.boolean)
            assertEquals(o.toString(), o["mode"].s(), d.mode.wire); assertEquals(o.toString(), o["auto"]!!.jsonPrimitive.boolean, d.auto)
        }
    }

    @Test fun rowNamesAreTheFixtureNamesAndNeverShareATitle() {
        val t = doc()!!["titles"]!!.jsonObject
        assertEquals(strs(t["rows"]), HomeRowNames.ROWS)
        val genres = t["genres"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
        assertEquals(genres, HomeRowNames.GENRES)
        assertEquals(genres.keys.toList(), GenreTable.all.map { it.key })
        val shown = HomeRowNames.ROWS.toList() + genres.values
        assertEquals(shown.size, shown.toSet().size)
        assertEquals("Quiet week: all time", HomeRowNames.QUIET_WEEK); assertEquals(20, HomeRowNames.QUIET_WEEK.length)
    }

    @Test fun layoutTokensAreTheSharedNumbers() {
        assertEquals(24, HomeLayoutTokens.ROW_GAP); assertEquals(12, HomeLayoutTokens.HEADER_TO_TILES); assertEquals(12, HomeLayoutTokens.TILE_GAP)
        assertEquals(30, HomeLayoutTokens.SUBTITLE_MIN_HEIGHT); assertEquals(3, HomeLayoutTokens.SKELETON_ROWS); assertEquals(48, HomeLayoutTokens.MIN_TARGET)
    }

    @Test fun moodFloorScalesWithTheLibrary() {
        assertEquals(8, HomeMoods.floor(0)); assertEquals(8, HomeMoods.floor(500)); assertEquals(15, HomeMoods.floor(1000)); assertEquals(300, HomeMoods.floor(20_000))
        assertEquals(listOf("withKids", "feelGood"), HomeMoods.allowed(true).map { it.key })
        assertTrue(HomeMoods.genreKeys(HomeMoods.of("mood:withKids")!!, true).all { GenreTable.of(it)!!.kids })
    }

    @Test fun twoMoodsAtMostAndKidsKeepTableOrder() {
        val all = listOf("mood:withKids", "mood:edge", "mood:feelGood")
        assertEquals(listOf("mood:withKids", "mood:edge"), HomeMoods.limit(all, "p", "2026-11-22", 0, true))
        assertEquals(2, HomeMoods.limit(all, "p", "2026-11-22", 0, false).size)
        assertEquals(HomeMoods.limit(all, "p", "2026-11-22", 3, false), HomeMoods.limit(all, "p", "2026-11-22", 3, false))
    }

    @Test fun contextOfTheDayFromTheClock() {
        assertTrue(HomeDayContext(5, 17).movieNight); assertFalse(HomeDayContext(5, 16).movieNight); assertTrue(HomeDayContext(7, 2).movieNight); assertFalse(HomeDayContext(1, 20).movieNight)
        assertTrue(HomeDayContext(6, 8).weekend); assertFalse(HomeDayContext(5, 8).weekend); assertTrue(HomeDayContext(3, 5).morning); assertFalse(HomeDayContext(3, 11).morning)
    }
}
