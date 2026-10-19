package app.streamsetu.tv

import app.streamsetu.core.model.Movie
import app.streamsetu.tv.ui.screens.section.Card
import app.streamsetu.tv.ui.screens.section.ContentFilter
import app.streamsetu.tv.ui.screens.section.FilterContext
import app.streamsetu.tv.ui.screens.section.FilterOptions
import app.streamsetu.tv.ui.screens.section.WatchStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContentFilterTests {
    private fun card(id: String, title: String, year: Int? = 2024, rating: String? = "7.5", category: String? = "c1", source: String = "s1"): Card {
        val m = Movie(id, source, category, title, null, year, rating, null, "ref")
        return Card(id, title, null, year, rating, source, movie = m)
    }

    private val ctx = FilterContext(watched = setOf("a"), partial = setOf("b"), favourites = setOf("c"), folderNames = mapOf("c1" to "Telugu Movies 4K", "c2" to "Action"))

    @Test fun languageComesFromTheTitleOrTheFolder() {
        assertTrue(ContentFilter(language = "English").accepts(card("1", "Whalefall (English)", category = "c2"), ctx))
        assertTrue(ContentFilter(language = "Telugu").accepts(card("2", "Lucky Baskhar", category = "c1"), ctx))
        assertFalse(ContentFilter(language = "Telugu").accepts(card("3", "Leo", category = "c2"), ctx))
    }

    @Test fun qualityRatingAndDecadeNarrowTheList() {
        assertTrue(ContentFilter(quality = "4K").accepts(card("1", "Film", category = "c1"), ctx))
        assertFalse(ContentFilter(quality = "4K").accepts(card("2", "Film", category = "c2"), ctx))
        assertFalse(ContentFilter(minRating = 8f).accepts(card("3", "Film"), ctx))
        assertTrue(ContentFilter(minRating = 7f).accepts(card("4", "Film"), ctx))
        assertTrue(ContentFilter(decade = 2020).accepts(card("5", "Film", year = 2024), ctx))
        assertFalse(ContentFilter(decade = 2010).accepts(card("6", "Film", year = 2024), ctx))
    }

    @Test fun statusUsesTheWatchedStartedAndFavoriteLists() {
        assertTrue(ContentFilter(status = WatchStatus.WATCHED).accepts(card("a", "A"), ctx))
        assertTrue(ContentFilter(status = WatchStatus.IN_PROGRESS).accepts(card("b", "B"), ctx))
        assertTrue(ContentFilter(status = WatchStatus.FAVORITES).accepts(card("c", "C"), ctx))
        assertTrue(ContentFilter(status = WatchStatus.UNWATCHED).accepts(card("d", "D"), ctx))
        assertFalse(ContentFilter(status = WatchStatus.UNWATCHED).accepts(card("a", "A"), ctx))
    }

    @Test fun optionsAreOnlyWhatTheListHasAndInAlphabeticalOrder() {
        val cards = listOf(card("1", "A (Turkish)", category = "c2"), card("2", "B (English)", category = "c2"), card("3", "C", category = "c1"))
        val options = FilterOptions.of(cards, ctx)
        assertEquals(listOf("English", "Telugu", "Turkish"), options.languages)
        assertEquals(listOf("Action", "Telugu Movies 4K"), options.folders.map { it.second })
        assertEquals(listOf("4K"), options.qualities)
    }

    @Test fun theCountIsTheNumberOfChoices() {
        assertEquals(0, ContentFilter().count)
        assertEquals(3, ContentFilter(language = "Hindi", minRating = 7f, decade = 2010).count)
    }
}
