package app.streamsetu.core.data

import app.streamsetu.core.data.repo.EpisodePlan
import app.streamsetu.core.data.repo.MaintenanceService
import app.streamsetu.core.model.*
import org.junit.Assert.*
import org.junit.Test

class CatalogLogicTests {
    private fun ep(season: Int, n: Int) = Episode("e$season-$n", "s", season, n, "T$n", null, null, null, "ref")
    private fun done(e: Episode) = e.id to WatchProgress(e.id, ContentKind.EPISODE, "s", 0, 1, 1, true)
    private fun partial(e: Episode) = e.id to WatchProgress(e.id, ContentKind.EPISODE, "s", 600_000, 3_000_000, 1, false)

    @Test fun freshSeriesStartsAtTheFirstEpisode() {
        val eps = listOf(ep(1, 1), ep(1, 2))
        val plan = EpisodePlan.of(eps, emptyMap())
        assertEquals(1, plan.forward?.number); assertNull(plan.catchUp); assertFalse(plan.gapBefore)
    }
    @Test fun continuesAfterTheFurthestFinishedEpisode() {
        val eps = (1..5).map { ep(1, it) }
        val plan = EpisodePlan.of(eps, mapOf(done(eps[0]), done(eps[1])))
        assertEquals(3, plan.forward?.number); assertNull(plan.catchUp)
    }
    @Test fun skippedEpisodeOffersCatchUpAndForward() {
        val eps = (1..5).map { ep(1, it) }
        val plan = EpisodePlan.of(eps, mapOf(done(eps[0]), done(eps[2])))     // 1 and 3 watched, 2 skipped
        assertEquals(2, plan.catchUp?.number); assertEquals(4, plan.forward?.number)
    }
    @Test fun missingNextEpisodeIsAGapAndNeverContinuousPlay() {
        val eps = listOf(ep(1, 1), ep(1, 2), ep(1, 4))                          // episode 3 is not in the catalog
        val plan = EpisodePlan.of(eps, mapOf(done(eps[0]), done(eps[1])))
        assertEquals(4, plan.forward?.number); assertTrue(plan.gapBefore)
        assertFalse(EpisodePlan.contiguous(eps[1], eps[2]))
        assertTrue(EpisodePlan.contiguous(eps[0], eps[1]))
    }
    @Test fun nextSeasonCountsAsContiguous() = assertTrue(EpisodePlan.contiguous(ep(1, 10), ep(2, 1)))
    @Test fun inProgressEpisodeIsOffered() {
        val eps = (1..3).map { ep(1, it) }
        assertEquals(2, EpisodePlan.of(eps, mapOf(done(eps[0]), partial(eps[1]))).inProgress?.number)
    }
    @Test fun allFinishedIsReported() {
        val eps = (1..2).map { ep(1, it) }
        assertTrue(EpisodePlan.of(eps, mapOf(done(eps[0]), done(eps[1]))).allFinished)
    }

    @Test fun sortSpecRoundTrips() {
        val s = SortSpec(SortField.YEAR, false, true, true)
        assertEquals(s, SortSpec.decode(s.encode()))
        assertEquals(SortSpec(), SortSpec.decode("garbage"))
    }
    @Test fun everythingStartsMostRecentlyAdded() {
        assertEquals(SortField.ADDED, SortSpec.defaultFor(ContentKind.MOVIE).field)
        assertEquals(SortField.ADDED, SortSpec.defaultFor(ContentKind.SERIES).field)
        assertEquals(SortField.ADDED, SortSpec.defaultFor(ContentKind.CHANNEL).field)
    }
    @Test fun sortOffersOnlyWhatTheCatalogHas() {
        val none = SortAvailability(false, false, false, false).offers(ContentKind.MOVIE)
        assertFalse(SortField.YEAR in none); assertFalse(SortField.RATING in none); assertFalse(SortField.RECENTLY_WATCHED in none)
        val all = SortAvailability(true, true, false, true).offers(ContentKind.MOVIE)
        assertTrue(SortField.YEAR in all && SortField.RATING in all && SortField.RECENTLY_WATCHED in all)
        assertFalse(SortField.YEAR in SortAvailability(true, true, false, true).offers(ContentKind.CHANNEL))
    }

    @Test fun diagnosticsRedactAddressesAndSecrets() {
        val t = MaintenanceService.redact("failed http://provider.example:80/live/user1/pass2/12.ts and password=hunter2&token=abc")
        assertFalse("provider" in t); assertFalse("hunter2" in t); assertFalse("abc" in t)
        assertTrue("<address>" in t)
    }
}
