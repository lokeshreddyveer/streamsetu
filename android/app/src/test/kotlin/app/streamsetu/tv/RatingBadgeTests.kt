package app.streamsetu.tv

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createComposeRule
import app.streamsetu.core.data.db.RatingCheckEntity
import app.streamsetu.core.data.repo.*
import app.streamsetu.tv.ui.components.LocalRatings
import app.streamsetu.tv.ui.components.RatingBadge
import app.streamsetu.tv.ui.components.TileRating
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** The star on every tile: one rule ([DisplayRating]), read for the titles on screen together, TMDB's asked once for a matched title, never for a restricted one; and every tile composable carries the badge. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class RatingBadgeTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()
    private lateinit var fx: PrivacyFixture
    private var key: String? = "0123456789abcdef0123456789abcdef"
    private val asked = java.util.Collections.synchronizedList(ArrayList<String>())
    private var reply = """{"id":9,"vote_average":8.14,"vote_count":900}"""

    @Before fun open() {
        fx = PrivacyFixture().build()
        fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET rating = NULL")
    }
    @After fun close() = fx.close()

    private fun badges(on: Boolean = true): Pair<RatingBadges, TmdbIdStore> {
        val ids = TmdbIdStore(fx.db)
        val auth = TmdbAuth({ key })
        return RatingBadges(fx.db, auth, ids, fx.folders.visibility, { u, _ -> asked += u; reply }, { on }, kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined), debounceMs = 5) to ids
    }
    private fun rate(id: String, r: String?) = fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET rating = ? WHERE id = ?", arrayOf(r, id))

    @Test fun theProviderRatingIsShownOnlyWhenCredibleAndReadForAWholeBatchAtOnce() = runBlocking {
        rate("m-plain-a", "7.5"); rate("m-plain-b", "10.0"); rate("m-other-a", "0"); rate(F.OPEN_FILM_A, "abc")
        val (b, _) = badges()
        for (id in listOf("m-plain-a", "m-plain-b", "m-other-a", F.OPEN_FILM_A, "m-other-b")) b.want(id)
        b.process()
        assertEquals(mapOf("m-plain-a" to 7.5), b.values.value)
        assertTrue("nothing was asked for titles that were never matched", asked.isEmpty())
    }

    @Test fun aMatchedTitleWithNoCredibleRatingIsAskedOnceAndTmdbWinsWhenEnoughVoted() = runBlocking {
        rate("m-plain-a", "5.5")
        val (b, ids) = badges(); ids.put("m-plain-a", 9, false); ids.put("m-other-a", 9, false)
        b.want("m-plain-a"); b.want("m-other-a"); b.process()
        // m-plain-a has a credible provider rating of its own, so nothing is asked; m-other-a has none: asked once
        assertEquals(1, asked.size); assertEquals(5.5, b.values.value.getValue("m-plain-a"), 0.0); assertEquals(8.1, b.values.value.getValue("m-other-a"), 0.0)
        assertEquals("remembered as asked", "8.1", fx.db.extras().ratingChecks(listOf("m-other-a")).single().tmdbRating)
        val (b2, ids2) = badges(); ids2.put("m-other-a", 9, false); b2.want("m-other-a"); b2.process()
        assertEquals("a second look reads it, it does not ask again", 1, asked.size); assertEquals(8.1, b2.values.value.getValue("m-other-a"), 0.0)
    }

    @Test fun fewVotesAreNotTrustedAndTheTitleIsStillNotAskedAgain() = runBlocking {
        reply = """{"id":9,"vote_average":10.0,"vote_count":2}"""
        val (b, ids) = badges(); ids.put("m-other-a", 9, false)
        b.want("m-other-a"); b.process()
        assertNull(b.values.value["m-other-a"]); assertEquals(1, asked.size)
        assertNull(fx.db.extras().ratingChecks(listOf("m-other-a")).single().tmdbRating)
        val (b2, ids2) = badges(); ids2.put("m-other-a", 9, false); b2.want("m-other-a"); b2.process(); assertEquals(1, asked.size)
    }

    @Test fun aRestrictedTitleIsNeverAskedAboutAndNothingIsAskedWithoutAKeyOrWithMatchingOff() = runBlocking {
        val (b, ids) = badges(); for (id in listOf(F.SECRET_A, F.SPLIT_A, F.LONE_B, F.HIDDEN_FILM_A, F.ADULT_FILM_A)) { ids.put(id, 9, false); b.want(id) }
        b.process(); assertTrue("asked: $asked", asked.isEmpty())
        key = null; val (c, ids2) = badges(); ids2.put("m-other-a", 9, false); c.want("m-other-a"); c.process(); assertTrue(asked.isEmpty())
        key = "0123456789abcdef0123456789abcdef"; val (d, ids3) = badges(on = false); ids3.put("m-other-b", 9, false); d.want("m-other-b"); d.process(); assertTrue(asked.isEmpty())
    }

    @Test fun clearingTakesTmdbsRatingsBack() = runBlocking {
        fx.db.extras().putRatingCheck(RatingCheckEntity("m-plain-a", "9.1", 1L))
        val (b, _) = badges(); b.want("m-plain-a"); b.process(); assertEquals(9.1, b.values.value["m-plain-a"]!!, 0.0)
        b.clearAll(); assertTrue(b.values.value.isEmpty()); assertTrue(fx.db.extras().ratingChecks(listOf("m-plain-a")).isEmpty())
    }

    @Test fun theBadgeIsReadAsRatedOutOfTenAndTheTileShowsNothingWithoutARating() {
        runBlocking { fx.db.extras().putRatingCheck(RatingCheckEntity("m-plain-a", "7.5", 1L)) }
        val (b, _) = badges(); b.want("m-plain-a"); runBlocking { b.process() }
        rule.setContent { androidx.compose.runtime.CompositionLocalProvider(LocalRatings provides b) { TileRating("m-plain-a"); TileRating("m-other-b"); RatingBadge(8.0) } }
        rule.waitForIdle()
        val descriptions = rule.onAllNodes(SemanticsMatcher("rated") { it.config.getOrNull(SemanticsProperties.ContentDescription)?.any { d -> d.startsWith("Rated ") } == true }).fetchSemanticsNodes().map { it.config.getOrNull(SemanticsProperties.ContentDescription)!!.first() }
        assertEquals(listOf("Rated 7.5 out of 10", "Rated 8.0 out of 10"), descriptions)
    }

    // ---- every tile composable carries the badge (audit)

    private fun main(path: String) = File("src/main/kotlin/app/streamsetu/tv/$path").readText()
    private fun fn(path: String, name: String): String { val t = main(path); val i = t.indexOf("fun $name("); require(i >= 0) { "$name not in $path" }; val j = t.indexOf("\n}\n", i); return t.substring(i, if (j < 0) t.length else j) }

    @Test fun everyTitleTileComposableDrawsTheSharedBadge() {
        val tiles = listOf("ui/components/Basics.kt" to "PosterCard", "ui/phone/PhoneKit.kt" to "PhonePoster", "ui/phone/PhoneKit.kt" to "PhoneWide", "ui/components/OtherLanguages.kt" to "VersionChip",
            "ui/screens/search/SearchContent.kt" to "SearchTile", "ui/screens/search/SearchContent.kt" to "SearchResultRow", "ui/screens/search/SearchContent.kt" to "BestMatchCard",
            "ui/screens/PersonContent.kt" to "FilmTileView", "ui/phone/PhoneMore.kt" to "Result")
        for ((p, f) in tiles) { val body = fn(p, f); assertTrue("$f in $p has no rating badge", "TileRating(" in body || "RatingBadge(" in body) }
        // PosterCard and PhonePoster put it after the tag, in the same corner
        assertTrue(fn("ui/components/Basics.kt", "PosterCard").let { it.indexOf("Label(badge") < it.indexOf("TileRating(") })
        assertTrue(fn("ui/phone/PhoneKit.kt", "PhonePoster").let { it.indexOf("Label(badge") < it.indexOf("TileRating(") })
    }

    @Test fun everyPosterCardAndPhonePosterCallNamesTheTitleSoTheBadgeCanBeRead() {
        // The badge is read by the title's id. Exempt, with the reason: live channels, episodes, folders, people and collections draw no PosterCard/PhonePoster with a title id of their own.
        val exempt = setOf<String>()
        val bad = ArrayList<String>()
        File("src/main/kotlin").walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { f ->
            val t = f.readText()
            Regex("\\b(PosterCard|PhonePoster)\\(").findAll(t).forEach { m ->
                if (t.substring(maxOf(0, m.range.first - 4), m.range.first).contains("fun ")) return@forEach
                var depth = 0; var i = m.range.last
                var end = i
                while (i < t.length) { val ch = t[i]; if (ch == '(') depth++ else if (ch == ')') { depth--; if (depth == 0) { end = i; break } }; i++ }
                val call = t.substring(m.range.last, end)
                if ("itemId" !in call && f.name !in exempt) bad += "${f.name}: ${t.substring(m.range.first, minOf(t.length, m.range.first + 70)).replace('\n', ' ')}"
            }
        }
        assertTrue("tiles that cannot show a rating (no itemId):\n" + bad.joinToString("\n"), bad.isEmpty())
    }
}
