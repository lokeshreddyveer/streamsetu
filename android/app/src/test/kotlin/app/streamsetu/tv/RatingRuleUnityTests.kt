package app.streamsetu.tv

import app.streamsetu.core.data.repo.*
import app.streamsetu.tv.ui.components.Facts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** One rating rule: the hero banners follow it like the tiles do (10.0, above 10 and 0 are junk), and the tile ratings kept in memory are bounded. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class RatingRuleUnityTests {
    private lateinit var fx: PrivacyFixture
    @Before fun open() { fx = PrivacyFixture().build(); fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET rating = NULL") }
    @After fun close() = fx.close()

    @Test fun theBannerTextAgreesWithTheSharedRule() {
        assertEquals("★ 7.5", Facts.rating("7.46")); assertEquals("★ 7.4", Facts.rating(" 7.4 "))
        for (junk in listOf("10", "10.0", "99", "0", "0.0", "abc", "", null, "-3")) assertNull("banner must hide $junk", Facts.rating(junk))
        for (raw in listOf("7.4", "10.0", "42", "0", "x", null)) assertEquals(raw, DisplayRating.starText(raw), Facts.rating(raw))
    }

    @Test fun theStarTextAlwaysUsesAPointDecimal() {
        val old = java.util.Locale.getDefault()
        try { java.util.Locale.setDefault(java.util.Locale("hi", "IN")); assertEquals("★ 8.1", DisplayRating.star(8.14)); java.util.Locale.setDefault(java.util.Locale.GERMANY); assertEquals("★ 8.1", Facts.rating("8.14")) }
        finally { java.util.Locale.setDefault(old) }
    }

    @Test fun theTmdbAndFilmographyRuleIsTheOneInDisplayRating() {
        assertNull(DisplayRating.credible(0.0, 500)); assertNull(DisplayRating.credible(8.0, 3)); assertNull(DisplayRating.credible(null, 100)); assertEquals(7.5, DisplayRating.credible(7.5, 10)!!, 0.0)
        assertEquals("8.1", DisplayRating.tmdbText(8.14, 900)); assertNull(DisplayRating.tmdbText(10.0, 2))
    }

    @Test fun theRatingsKeptForTilesAreCappedAndTheNewestStay() = runBlocking {
        val ids = listOf("m-plain-a", "m-plain-b", "m-other-a", "m-other-b")
        ids.forEachIndexed { i, id -> fx.db.openHelper.writableDatabase.execSQL("UPDATE movies SET rating = ? WHERE id = ?", arrayOf("${5 + i}.5", id)) }
        val b = RatingBadges(fx.db, TmdbAuth({ null }), TmdbIdStore(fx.db), fx.folders.visibility, { _, _ -> "{}" }, { false }, kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined), debounceMs = 5, maxValues = 2)
        for (id in ids) { b.want(id); b.process() }
        assertEquals("at most two kept", 2, b.values.value.size)
        assertEquals(setOf("m-other-a", "m-other-b"), b.values.value.keys)          // the newest two
        assertEquals(8.5, b.values.value.getValue("m-other-b"), 0.0)
    }
}
