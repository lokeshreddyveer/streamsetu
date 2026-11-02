package app.streamsetu.core.data

import app.streamsetu.core.addon.AddonCatalog
import app.streamsetu.core.addon.AddonCategory
import app.streamsetu.core.addon.AddonItem
import app.streamsetu.core.sync.AddonSync
import org.junit.Assert.*
import org.junit.Test

class AddonSyncTests {
    private val catalog = AddonCatalog(
        categories = listOf(AddonCategory("d", "Drama")),
        channels = listOf(AddonItem("n1", "News", category = "d", url = "https://cdn.example.com/n1.m3u8", number = 7)),
        movies = listOf(AddonItem("m1", "First", category = "d", year = 2020), AddonItem("m2", "Second", url = "https://cdn.example.com/m2.m3u8")),
        dropped = 0,
    )
    private val rows = AddonSync.toRows("addon.x", catalog, now = 1_000)

    @Test fun everyIdBelongsToTheAddonSoNothingCanOverwriteAnotherConnection() {
        assertTrue(rows.channels.all { it.id.startsWith("addon.x:c:") && it.sourceId == "addon.x" })
        assertTrue(rows.movies.all { it.id.startsWith("addon.x:m:") && it.sourceId == "addon.x" })
        assertTrue(rows.categories.all { it.id.startsWith("addon.x:cat:") })
    }

    @Test fun aFolderIsMadeForEachKindThatUsesIt() {
        assertEquals(setOf("CHANNEL", "MOVIE"), rows.categories.map { it.kind }.toSet())
        assertEquals("Drama", rows.categories.first().name)
        assertEquals(rows.categories.first { it.kind == "MOVIE" }.id, rows.movies.first().categoryId)
        assertNull(rows.movies[1].categoryId)
    }

    @Test fun aTitleWithoutAnAddressIsAskedForWhenPlayedAndOneWithAnAddressPlaysIt() {
        assertEquals("addon:m:m1", rows.movies[0].streamRef)
        assertEquals("https://cdn.example.com/m2.m3u8", rows.movies[1].streamRef)
        assertEquals(7, rows.channels.single().number)
    }

    @Test fun aSeriesComesWithItsEpisodesAndEachGetsItsOwnReference() {
        val withSeries = AddonCatalog(emptyList(), emptyList(), emptyList(), 0, listOf(app.streamsetu.core.addon.AddonSeries("s1", "Show", episodes = listOf(
            app.streamsetu.core.addon.AddonEpisode("e1", 1, 1, "Pilot", minutes = 45), app.streamsetu.core.addon.AddonEpisode("e2", 1, 2, "", url = "https://cdn.example.com/e2.m3u8")))))
        val r = AddonSync.toRows("addon.x", withSeries)
        assertEquals("addon.x:s:s1", r.series.single().id); assertEquals(setOf("addon.x:s:s1"), r.episodes.map { it.seriesId }.toSet())
        assertEquals("addon:e:e1", r.episodes[0].streamRef); assertEquals(2700, r.episodes[0].durationSec); assertEquals("Episode 2", r.episodes[1].title)
        assertEquals("https://cdn.example.com/e2.m3u8", r.episodes[1].streamRef)
    }

    @Test fun aLazyReferenceBecomesAQuestionAboutOneKindOfThing() {
        assertEquals(mapOf("kind" to "episode", "id" to "e1"), AddonSync.lazyQuestion("e:e1")); assertEquals(mapOf("kind" to "movie", "id" to "a:b"), AddonSync.lazyQuestion("m:a:b"))
        assertNull(AddonSync.lazyQuestion("x:1")); assertNull(AddonSync.lazyQuestion("m:"))
    }

    @Test fun theAddonsOwnOrderIsKept() { assertTrue(rows.movies[0].addedAt > rows.movies[1].addedAt) }
}
